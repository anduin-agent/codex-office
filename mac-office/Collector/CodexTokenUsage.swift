import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import OfficeZstd

/// Caches token counters, model identifiers and allowance data in the background usage actor.
final class CodexTokenUsage {
    private static let liveWindow: TimeInterval = 60
    private static let liveFileMargin: TimeInterval = 60
    private static let historyDays = 30
    private static let quotaEstimateTolerance = 0.15
    private let home: URL
    private var files: [URL: UsageFile] = [:]
    private var failures: [URL: Failure] = [:]
    private var sessions: [String: UsageSummary] = [:]
    private var rolloutThreads: [String: UsageFile] = [:]
    private var summaryTimeZone: TimeZone?
    private var historyDates: [String: Date] = [:]
    private var latestPrices = OfficePrices.empty
    private var detailStatus = "loading"
    private var detailToday: Date?

    init(home: URL) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }

    func scan(now: Date = Date(), budget: TimeInterval = 1.2, prices: OfficePrices = .empty,
              quotaAccount: String? = nil) -> OfficeJSON {
        latestPrices = prices
        let costs = UsageCostCalculator(prices)
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + budget
        let inventory = discoverLogs()
        let previousFiles = Dictionary(files.values.map { ($0.signature, $0) },
                                       uniquingKeysWith: { first, _ in first })
        files = files.filter { inventory.logs[$0.key] != nil }
        failures = failures.filter { inventory.logs[$0.key] != nil }
        var pending: [UsageFileSignature] = []
        var failed: [UsageFileSignature] = []
        let ordered = inventory.logs.sorted { left, right in
            if left.value.modifiedSeconds != right.value.modifiedSeconds {
                return left.value.modifiedSeconds > right.value.modifiedSeconds
            }
            if left.value.modifiedNanoseconds != right.value.modifiedNanoseconds {
                return left.value.modifiedNanoseconds > right.value.modifiedNanoseconds
            }
            return left.key.path < right.key.path
        }
        for (path, signature) in ordered {
            let previous = files[path] ?? previousFiles[signature]
            if let previous, previous.signature == signature {
                files[path] = previous
                continue
            }
            if let failure = failures[path], failure.signature == signature, start < failure.retryAt {
                failed.append(signature)
                continue
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                pending.append(signature)
                continue
            }
            do {
                files[path] = try readUsageFile(path, signature: signature, previous: previous)
                failures.removeValue(forKey: path)
            } catch {
                failures[path] = Failure(signature: signature, retryAt: start + 30)
                failed.append(signature)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        updateSummaries(calendar: calendar)
        let cutoff = now.addingTimeInterval(-Self.liveWindow)
        let today = calendar.startOfDay(for: now)
        let firstChartDay = calendar.date(byAdding: .day, value: 1 - Self.historyDays, to: today) ?? today
        var recent: [UsageRankedSession] = []
        var history: [Date: Int] = [:]
        var breakdowns: [Date: UsageBreakdown] = [:]
        var estimates: [Date: UsageEstimate] = [:]
        var historyEstimate = UsageEstimate()
        var liveEstimate = UsageEstimate()
        var todayTokens = 0
        for (id, summary) in sessions {
            let count = summary.total(through: now) - summary.total(through: cutoff)
            if count > 0 {
                let estimate = summary.liveEstimate(after: cutoff, through: now, costs: costs)
                recent.append(UsageRankedSession(id: id, tokens: count, estimate: estimate))
                liveEstimate.add(estimate)
            }
            if pending.isEmpty {
                for (day, tokens) in summary.days where day <= today {
                    history[day] = addingTokens(history[day, default: 0], tokens)
                }
                for (day, breakdown) in summary.breakdownDays where day >= firstChartDay && day <= today {
                    breakdowns[day, default: UsageBreakdown()].add(breakdown)
                }
            }
            for (day, amounts) in summary.priceableDays where day == today || (pending.isEmpty && day < today) {
                let estimate = costs.estimate(amounts)
                if day >= firstChartDay { estimates[day, default: UsageEstimate()].add(estimate) }
                historyEstimate.add(estimate)
            }
            todayTokens = addingTokens(todayTokens, summary.days[today, default: 0])
        }
        recent.sort(by: UsageRankedSession.rankedBefore)

        let liveCutoff = cutoff.addingTimeInterval(-Self.liveFileMargin)
        let liveStatus = status(inventory.foundRoot, pending: pending.contains { $0.modified >= liveCutoff },
                                failed: inventory.hadErrors || failed.contains { $0.modified >= liveCutoff })
        let todayStatus = status(inventory.foundRoot, pending: pending.contains { $0.modified >= today },
                                 failed: inventory.hadErrors || failed.contains { $0.modified >= today })
        let historyStatus = status(inventory.foundRoot, pending: !pending.isEmpty,
                                   failed: inventory.hadErrors || !failed.isEmpty)
        detailStatus = historyStatus
        detailToday = today
        historyDates.removeAll(keepingCapacity: true)
        let historyValue: OfficeJSON? = hasCounts(historyStatus)
            ? historyPayload(history, breakdowns: breakdowns, estimates: estimates, totalEstimate: historyEstimate,
                             priceDate: prices.updatedAt, today: today, calendar: calendar) : nil
        let quota = quotaWindows(at: now, account: quotaAccount, pending: pending, failed: failed,
                                 inventoryErrors: inventory.hadErrors)
        var snapshot: OfficeJSON = [
            "live_status": liveStatus,
            "history_status": historyStatus,
            "window_minutes": 1,
            "tokens_per_minute": hasCounts(liveStatus) ? recent.map(\.tokens).reduce(0, addingTokens) as Any : NSNull(),
            "today_status": todayStatus,
            "today_tokens": hasCounts(todayStatus) ? todayTokens as Any : NSNull(),
            "quota": quota.active.first as Any? ?? NSNull(),
            "quota_windows": Array(quota.active.reversed()),
            "quota_closed_windows": quota.closed,
            "quota_plan": quota.plan as Any? ?? NSNull(),
            "quota_account": quota.account as Any? ?? NSNull(),
            "quota_sampled_at": quota.stamp.map(officeISODate) as Any? ?? NSNull(),
            "recent": hasCounts(liveStatus) ? recent.prefix(8).map { session -> OfficeJSON in
                var row: OfficeJSON = ["id": session.id, "tokens": session.tokens]
                session.estimate.write(to: &row)
                return row
            } : [],
            "history": historyValue as Any? ?? NSNull(),
        ]
        if hasCounts(todayStatus) { estimates[today]?.write(to: &snapshot, prefix: "today_") }
        if hasCounts(liveStatus) { liveEstimate.write(to: &snapshot, prefix: "live_") }
        return snapshot
    }

    func dayDetails(_ day: String, language: OfficeLanguage = .simplifiedChinese) -> OfficeJSON {
        guard let date = historyDates[day] else { return ["day": day, "sessions": [], "total_sessions": 0] }
        let costs = UsageCostCalculator(latestPrices)
        let candidates = sessions.compactMap { id, summary -> UsageRankedSession? in
            guard let tokens = summary.days[date], tokens > 0 else { return nil }
            let estimate = summary.priceableDays[date].map(costs.estimate) ?? UsageEstimate()
            return UsageRankedSession(id: id, tokens: tokens, estimate: estimate)
        }
        let grouping = rankingRelations()
        let ranked = groupUsage(candidates, by: grouping)
        let rows = rankingPayload(Array(ranked.prefix(100)), grouping: grouping, language: language)
        return ["day": day, "sessions": rows, "total_sessions": ranked.count]
    }

    func detailedUsage(_ query: OfficeJSON, language: OfficeLanguage, settings: OfficeSettings) -> OfficeJSON {
        guard let date = detailToday, let zone = summaryTimeZone, hasCounts(detailStatus) else {
            return ["status": detailStatus]
        }
        guard let filters = DetailedUsageFilters(query, zone: zone) else { return ["status": "invalid"] }

        let preferences = (try? settings.load()) ?? OfficeSettings.defaults()
        let activityProjects = ActivityProjects(preferences)
        let temporary = Set((preferences["thread_projects"] as? OfficeJSON ?? [:]).compactMap { key, value in
            value is NSNull ? officeThreadID(key) : nil
        })
        let candidates = sessions.compactMap { id, summary -> (id: String, workspace: String?, models: [String: Int])? in
            var models: [String: Int] = [:]
            for (day, tokens) in summary.modelDays
            where day <= date && day >= filters.firstDay && day <= filters.lastDay {
                for (model, amount) in tokens {
                    models[model] = addingTokens(models[model, default: 0], amount)
                }
            }
            return models.isEmpty ? nil : (id, summary.workspace, models)
        }
        let grouping = rankingRelations()
        let rootWorkspaces = candidates.compactMap { candidate in
            grouping.root(for: candidate.id).flatMap { rolloutThreads[$0]?.workspace ?? sessions[$0]?.workspace }
        }
        activityProjects.discover(Set(candidates.compactMap(\.workspace) + rootWorkspaces))
        let knownProjects = Dictionary(uniqueKeysWithValues: activityProjects.rows().compactMap { project -> (String, String)? in
            guard let id = project["id"] as? String, let name = project["name"] as? String else { return nil }
            return (id, name)
        })
        let unknownProject = language.text("未归属项目", "Unassigned project")
        let unknownModel = language.text("未知模型", "Unknown model")
        let unknown = DetailedUsageFilters.unknown
        var projects: [String: String] = [:]
        var models: [String: String] = [:]
        var matching: [UsageRankedSession] = []
        var totalTokens = 0
        var totalEstimate = UsageEstimate()
        let costs = UsageCostCalculator(latestPrices)
        func projectFor(_ id: String, workspace: String?) -> (String, String) {
            detailedUsageProject(id: id, workspace: workspace, activityProjects: activityProjects,
                                 knownProjects: knownProjects, temporary: temporary, fallback: unknownProject)
        }
        for candidate in candidates {
            let id = candidate.id
            var (project, title) = projectFor(id, workspace: candidate.workspace)
            if project == unknown && !temporary.contains(id), let root = grouping.root(for: id), root != id {
                (project, title) = projectFor(root, workspace: rolloutThreads[root]?.workspace ?? sessions[root]?.workspace)
            }
            projects[project] = title
            for model in candidate.models.keys {
                models[model] = model == unknown ? unknownModel : String(model.dropFirst("model:".count))
            }
            guard filters.project.isEmpty || filters.project == project else { continue }
            let includedModels = filters.model.isEmpty ? candidate.models : candidate.models.filter { $0.key == filters.model }
            guard !includedModels.isEmpty else { continue }
            let tokens = includedModels.values.reduce(0, addingTokens)
            totalTokens = addingTokens(totalTokens, tokens)
            var modelEstimates: [String: UsageEstimate] = [:]
            var estimate = UsageEstimate()
            for (day, amounts) in sessions[id]?.priceableDays ?? [:]
            where day <= date && day >= filters.firstDay && day <= filters.lastDay {
                for (key, breakdown) in amounts {
                    let modelID = "model:" + key.model
                    guard includedModels[modelID] != nil else { continue }
                    let part = costs.estimate(key, breakdown)
                    modelEstimates[modelID, default: UsageEstimate()].add(part)
                    estimate.add(part)
                }
            }
            totalEstimate.add(estimate)
            matching.append(UsageRankedSession(id: id, tokens: tokens, project: title, models: includedModels,
                                              estimate: estimate, modelEstimates: modelEstimates))
        }
        let ranked = groupUsage(matching, by: grouping) { id in
            projectFor(id, workspace: rolloutThreads[id]?.workspace ?? sessions[id]?.workspace).1
        }
        let page = Array(ranked.dropFirst(filters.offset).prefix(100))
        let rows = rankingPayload(page, grouping: grouping, language: language, modelTitles: models)
        var payload: OfficeJSON = [
            "status": detailStatus, "projects": detailedUsageOptions(projects), "models": detailedUsageOptions(models),
            "total_tokens": totalTokens, "total_sessions": ranked.count, "sessions": rows
        ]
        totalEstimate.write(to: &payload)
        return payload
    }

    private func rankingRelations() -> UsageRankingRelations {
        let database = usageThreadRelations(home: home)
        let relations = rolloutThreads.compactMapValues(\.relation).merging(database.relations) { $0.fillingMissingFields(from: $1) }
        return UsageRankingRelations(knownIDs: database.ids.union(rolloutThreads.keys), relations: relations)
    }

    private func groupUsage(_ candidates: [UsageRankedSession], by grouping: UsageRankingRelations,
                            projectFor: (String) -> String? = { _ in nil }) -> [UsageRankedGroup] {
        let groups = Dictionary(grouping: candidates) { session in
            grouping.root(for: session.id) ?? UsageRankedGroup.unassigned
        }
        return groups.map { id, sessions in
            let own = sessions.first { $0.id == id }
            if let own, sessions.count == 1 { return UsageRankedGroup(session: own, children: []) }
            let children = sessions.filter { $0.id != id }.sorted(by: UsageRankedSession.rankedBefore)
            var modelTotals: [String: Int] = [:]
            var modelEstimates: [String: UsageEstimate] = [:]
            var estimate = UsageEstimate()
            for row in sessions {
                estimate.add(row.estimate)
                for (model, tokens) in row.models {
                    modelTotals[model] = addingTokens(modelTotals[model, default: 0], tokens)
                }
                for (model, cost) in row.modelEstimates {
                    modelEstimates[model, default: UsageEstimate()].add(cost)
                }
            }
            let group = UsageRankedSession(id: id, tokens: sessions.reduce(0) { addingTokens($0, $1.tokens) },
                                           project: projectFor(id) ?? own?.project, models: modelTotals,
                                           estimate: estimate, modelEstimates: modelEstimates)
            let root = id == UsageRankedGroup.unassigned ? [] :
                [own ?? UsageRankedSession(id: id, tokens: 0, project: group.project)]
            return UsageRankedGroup(session: group, children: root + children)
        }.sorted { UsageRankedSession.rankedBefore($0.session, $1.session) }
    }

    private func rankingPayload(_ groups: [UsageRankedGroup], grouping: UsageRankingRelations,
                                language: OfficeLanguage, modelTitles: [String: String]? = nil) -> [OfficeJSON] {
        let ids = Set(groups.flatMap { [$0.session.id] + $0.children.map(\.id) }).subtracting([UsageRankedGroup.unassigned])
        let names = activityNames(home: home, ids: ids)
        func row(_ session: UsageRankedSession) -> OfficeJSON {
            let id = session.id
            var metadata = names[id] ?? [:]
            metadata["thread_source"] = metadata["thread_source"] ?? grouping.relations[id]?.kind.rawValue
            let title = id == UsageRankedGroup.unassigned
                ? language.text("未归属的自动审批", "Unassigned automatic reviews")
                : activityChatLabel(metadata, id: id, language: language)
            var payload: OfficeJSON = ["id": id, "title": title, "tokens": session.tokens]
            session.estimate.write(to: &payload)
            if let project = session.project { payload["project"] = project }
            if let modelTitles {
                let totals = session.models.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                payload["models"] = totals.compactMap { modelTitles[$0.key] }
                payload["model_totals"] = totals.compactMap { key, tokens -> OfficeJSON? in
                    guard let title = modelTitles[key] else { return nil }
                    var row: OfficeJSON = ["title": title, "tokens": tokens]
                    session.modelEstimates[key]?.write(to: &row)
                    return row
                }
            }
            return payload
        }
        return groups.map { group in
            let id = group.session.id
            var payload = row(group.session)
            if id == UsageRankedGroup.unassigned { payload["kind"] = "unassigned_guardian" }
            if !group.children.isEmpty {
                payload["children"] = group.children.map { child in
                    var details = row(child)
                    details["kind"] = child.id == id ? "self" : grouping.relations[child.id]?.kind.rawValue ?? "subagent"
                    return details
                }
            }
            return payload
        }
    }

    private func detailedUsageProject(id: String, workspace: String?, activityProjects: ActivityProjects,
                                      knownProjects: [String: String], temporary: Set<String>, fallback: String) -> (String, String) {
        if let project = activityProjects.membership(id: id, workspace: workspace), let name = knownProjects[project] {
            return (project, name)
        }
        guard let workspace, !temporary.contains(id) else { return (DetailedUsageFilters.unknown, fallback) }
        let name = URL(fileURLWithPath: workspace).lastPathComponent
        return ("cwd:" + officeDigest(workspace, length: 24), name.isEmpty ? workspace : name)
    }

    private func detailedUsageOptions(_ values: [String: String]) -> [OfficeJSON] {
        values.sorted {
            let comparison = $0.value.localizedStandardCompare($1.value)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }.map { ["id": $0.key, "title": $0.value] }
    }

    private func discoverLogs() -> (logs: [URL: UsageFileSignature], foundRoot: Bool, hadErrors: Bool) {
        let manager = FileManager.default
        var logs: [URL: UsageFileSignature] = [:]
        var foundRoot = false
        var hadErrors = false
        for directory in ["sessions", "archived_sessions"] {
            let base = home.appendingPathComponent(directory, isDirectory: true).resolvingSymlinksInPath()
            var rootInfo = stat()
            guard lstat(base.path, &rootInfo) == 0 else {
                if errno != ENOENT { hadErrors = true }
                continue
            }
            guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else { continue }
            foundRoot = true
            guard let entries = manager.enumerator(at: base, includingPropertiesForKeys: nil, errorHandler: { _, _ in
                hadErrors = true
                return true
            }) else {
                hadErrors = true
                continue
            }
            for case let path as URL in entries {
                let name = path.lastPathComponent
                guard name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { continue }
                var info = stat()
                guard lstat(path.path, &info) == 0 else {
                    if errno != ENOENT { hadErrors = true }
                    continue
                }
                if (info.st_mode & S_IFMT) == S_IFREG {
                    logs[path] = UsageFileSignature(info)
                }
            }
        }
        return (logs, foundRoot, hadErrors)
    }

    private func updateSummaries(calendar: Calendar) {
        if summaryTimeZone != calendar.timeZone {
            sessions.removeAll()
            summaryTimeZone = calendar.timeZone
        }
        var groups: [String: [UsageFile]] = [:]
        rolloutThreads.removeAll(keepingCapacity: true)
        for (_, source) in files.sorted(by: { $0.key.path < $1.key.path }) {
            if let identity = source.identity {
                if let previous = rolloutThreads[identity] {
                    if source.hasMetadata && !previous.hasMetadata { rolloutThreads[identity] = source }
                } else {
                    rolloutThreads[identity] = source
                }
                guard !source.entries.isEmpty else { continue }
                groups[identity, default: []].append(source)
            }
        }
        sessions = groups.mapValues { sources in
            let signatures = sources.map(\.signature)
            if let identity = sources.first?.identity, let cached = sessions[identity], cached.signatures == signatures {
                return cached
            }
            return UsageSummary(sources: sources, signatures: signatures, calendar: calendar)
        }
    }

    private func quotaWindows(at now: Date, account: String?, pending: [UsageFileSignature], failed: [UsageFileSignature],
                              inventoryErrors: Bool) -> (active: [OfficeJSON], closed: [OfficeJSON], plan: String?,
                                                        account: String?, stamp: Date?) {
        var newest: (report: QuotaReport, account: String?)?
        for (_, file) in files.sorted(by: { $0.key.path < $1.key.path }) {
            guard account == nil || account == file.account,
                  let report = file.quota, report.stamp <= now else { continue }
            if let newest, newest.report.stamp >= report.stamp { continue }
            newest = (report, file.account)
        }
        // A newer plan can make an old report misleading. Only look within the latest report.
        guard let newest else { return ([], [], nil, nil, nil) }
        var active: [OfficeJSON] = []
        var closed: [OfficeJSON] = []
        var durations = Set<Int>()
        for window in newest.report.windows where durations.insert(window.minutes).inserted {
            if window.resets.map({ now >= $0 }) == true {
                if window.tracksCycle, let account = newest.account,
                   let previous = previousCycle(minutes: window.minutes, through: now, account: account) {
                    let ended = closedCycle(previous, account: account, pending: pending, failed: failed,
                                            inventoryErrors: inventoryErrors)
                    closed.append(["window_minutes": window.minutes, "previous_cycle": ended.payload])
                }
                continue
            }
            var payload: OfficeJSON = [
                "remaining_percent": window.remaining,
                "window_minutes": window.minutes,
                "resets_at": window.resets.map(officeISODate) as Any? ?? NSNull(),
            ]
            guard window.tracksCycle, let resets = window.resets, let start = window.starts,
                  start <= newest.report.stamp else {
                active.append(payload)
                continue
            }
            payload["cycle_started_at"] = officeISODate(start)
            let sample = QuotaSample(window: window, resets: resets, stamp: newest.report.stamp, plan: newest.report.plan)
            let current = cycleUsage(latest: sample, basis: sample, account: newest.account, through: now,
                                     closed: false, pending: pending, failed: failed, inventoryErrors: inventoryErrors)
            current.write(to: &payload)

            if let account = newest.account,
               let previous = previousCycle(minutes: window.minutes, through: start, account: account) {
                let ended = closedCycle(previous, account: account, pending: pending, failed: failed,
                                        inventoryErrors: inventoryErrors)
                payload["previous_cycle"] = ended.payload
                if let prior = ended.estimate, let live = current.estimate, previous.latest.planMatches(sample) {
                    let tolerance = Self.quotaEstimateTolerance
                    let ratio = Double(live) / Double(prior)
                    let comparison = ratio * (1 + tolerance) < (1 - tolerance) ? "lower"
                        : ratio * (1 - tolerance) > (1 + tolerance) ? "higher" : "similar"
                    payload["cycle_comparison"] = [
                        "status": comparison,
                        "change_percent": (ratio - 1) * 100,
                        "tolerance_percent": tolerance * 100,
                    ]
                }
            }
            active.append(payload)
        }
        return (active, closed, newest.report.plan, newest.account, newest.report.stamp)
    }

    private func closedCycle(_ samples: QuotaCycleSamples, account: String, pending: [UsageFileSignature],
                             failed: [UsageFileSignature], inventoryErrors: Bool) -> (payload: OfficeJSON, estimate: Int?) {
        let last = samples.latest
        let closed = cycleUsage(latest: last, basis: samples.basis, account: account, through: last.resets,
                                closed: true, pending: pending, failed: failed, inventoryErrors: inventoryErrors)
        var payload: OfficeJSON = [
            "resets_at": officeISODate(last.resets),
            "sampled_at": officeISODate(last.stamp),
            "used_percent": last.window.used,
        ]
        closed.write(to: &payload)
        if let basis = samples.basis, let matched = closed.matchedTokens {
            payload["basis_tokens"] = matched
            payload["basis_used_percent"] = basis.window.used
            payload["basis_sampled_at"] = officeISODate(basis.stamp)
        }
        return (payload, closed.estimate)
    }

    private func previousCycle(minutes: Int, through cutoff: Date, account: String) -> QuotaCycleSamples? {
        var previous: QuotaCycleSamples?
        for (_, file) in files.sorted(by: { $0.key.path < $1.key.path }) where file.account == account && file.usesOpenAI {
            for (key, samples) in file.quotaCycles where key.minutes == minutes && key.resets <= cutoff {
                if let prior = previous {
                    guard prior.latest.resets <= key.resets else { continue }
                    if prior.latest.resets == key.resets {
                        previous?.record(samples.latest)
                        if let basis = samples.basis { previous?.record(basis) }
                        continue
                    }
                }
                previous = samples
            }
        }
        return previous
    }

    private func cycleUsage(latest: QuotaSample, basis: QuotaSample?, account: String?, through end: Date, closed: Bool,
                            pending: [UsageFileSignature], failed: [UsageFileSignature], inventoryErrors: Bool) -> QuotaCycleUsage {
        let start = latest.resets.addingTimeInterval(-Double(latest.window.minutes) * 60)
        guard !pending.contains(where: { $0.modified >= start }) else { return QuotaCycleUsage(status: "loading") }
        let basis = basis.flatMap { $0.canEstimate && $0.planMatches(latest) ? $0 : nil }
        var observed = 0
        var atSnapshot = 0
        var partial = inventoryErrors || failed.contains { $0.modified >= start }
        for (id, summary) in sessions {
            let source = rolloutThreads[id]
            guard source?.usesOpenAI != false else { continue }
            if let account, let other = source?.account, other != account { continue }
            let baseline = summary.total(through: start, inclusive: false)
            let tokens = summary.total(through: end, inclusive: !closed) - baseline
            guard tokens > 0 else { continue }
            if account == nil || source?.account == nil { partial = true }
            observed = addingTokens(observed, tokens)
            if let basis {
                atSnapshot = addingTokens(atSnapshot, summary.total(through: basis.stamp) - baseline)
            }
        }
        let estimate = basis.flatMap { sample in
            !partial && atSnapshot > 0 ? Int(exactly: (Double(atSnapshot) / (sample.window.used / 100)).rounded()) : nil
        }
        return QuotaCycleUsage(status: partial ? "partial" : "ok", observed: observed,
                               estimate: estimate, matchedTokens: estimate == nil ? nil : atSnapshot)
    }

    private func historyPayload(_ history: [Date: Int], breakdowns: [Date: UsageBreakdown],
                                estimates: [Date: UsageEstimate], totalEstimate: UsageEstimate, priceDate: String,
                                today: Date, calendar: Calendar) -> OfficeJSON {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let days: [OfficeJSON] = (0..<Self.historyDays).reversed().compactMap { daysAgo in
            guard let target = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { return nil }
            let date = calendar.startOfDay(for: target)
            let key = formatter.string(from: date)
            historyDates[key] = date
            var row: OfficeJSON = ["day": key, "tokens": history[date, default: 0]]
            if let breakdown = breakdowns[date] {
                row["input_tokens"] = breakdown.input
                row["output_tokens"] = breakdown.output
                row["breakdown_tokens"] = breakdown.total
                if let cached = breakdown.cached {
                    row["cached_input_tokens"] = cached
                    row["cache_reported_input_tokens"] = breakdown.cacheReportedInput
                }
            }
            estimates[date]?.write(to: &row, components: true)
            return row
        }
        var payload: OfficeJSON = [
            "total_tokens": history.values.reduce(0, addingTokens),
            "active_days": history.count,
            "first_day": history.keys.min().map(formatter.string(from:)) as Any? ?? NSNull(),
            "days": days,
        ]
        totalEstimate.write(to: &payload, prefix: "total_")
        if totalEstimate.tokens > 0, !priceDate.isEmpty { payload["prices_updated_at"] = priceDate }
        return payload
    }

    private func status(_ foundRoot: Bool, pending: Bool, failed: Bool) -> String {
        if !foundRoot { return "unavailable" }
        if pending { return "loading" }
        return failed ? "partial" : "ok"
    }

    private func hasCounts(_ status: String) -> Bool {
        status == "ok" || status == "partial"
    }

    private struct Failure {
        let signature: UsageFileSignature
        let retryAt: TimeInterval
    }
}

private struct DetailedUsageFilters {
    static let unknown = "__unknown__"

    let firstDay: Date
    let lastDay: Date
    let project: String
    let model: String
    let offset: Int

    init?(_ query: OfficeJSON, zone: TimeZone) {
        guard let from = Self.string(query["from"], limit: 10),
              let to = Self.string(query["to"], limit: 10),
              let project = Self.string(query["project"], limit: 128),
              let model = Self.string(query["model"], limit: 128) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        func parse(_ value: String, default fallback: Date) -> Date? {
            if value.isEmpty { return fallback }
            guard value.utf8.count == 10, let date = formatter.date(from: value),
                  formatter.string(from: date) == value else { return nil }
            return date
        }
        guard let first = parse(from, default: .distantPast),
              let last = parse(to, default: .distantFuture),
              first <= last else { return nil }
        let offset: Int
        if let raw = query["offset"] {
            guard let parsed = usageInteger(raw), parsed >= 0 else { return nil }
            offset = parsed
        } else {
            offset = 0
        }
        self.firstDay = first
        self.lastDay = last
        self.project = project
        self.model = model
        self.offset = offset
    }

    private static func string(_ value: Any?, limit: Int) -> String? {
        guard let value else { return "" }
        guard let string = value as? String, string.utf8.count <= limit else { return nil }
        return string
    }
}

private struct UsageRankedSession {
    let id: String
    let tokens: Int
    var project: String? = nil
    var models: [String: Int] = [:]
    var estimate = UsageEstimate()
    var modelEstimates: [String: UsageEstimate] = [:]

    static func rankedBefore(_ first: Self, _ second: Self) -> Bool {
        first.tokens == second.tokens ? first.id < second.id : first.tokens > second.tokens
    }
}

private struct UsageRankedGroup {
    static let unassigned = "unassigned-guardian"

    let session: UsageRankedSession
    let children: [UsageRankedSession]
}

private struct UsageRankingRelations {
    let knownIDs: Set<String>
    let relations: [String: UsageThreadRelation]

    func root(for id: String) -> String? {
        let unlinked = relations[id]?.kind == .guardianReview ? nil : id
        var current = id
        var seen: Set<String> = [id]
        var explicitRoot: String?
        while let relation = relations[current] {
            if let root = relation.root, root != current, knownIDs.contains(root), relations[root] == nil {
                explicitRoot = root
            }
            guard let parent = relation.parent, knownIDs.contains(parent), seen.insert(parent).inserted else {
                return explicitRoot ?? unlinked
            }
            current = parent
        }
        return current
    }
}

private struct UsageFileSignature: Hashable {
    let device: dev_t
    let inode: ino_t
    let size: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = UInt64(max(0, info.st_size))
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    var modified: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    func isSameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }
}

private struct UsageEventKey: Hashable {
    let stamp: Date
    let total: Int?
    let last: Int?
}

private struct UsageEvent {
    let key: UsageEventKey
    let model: String?
    let pricedModel: String?
    let breakdown: UsageBreakdown?

    var detailRank: Int {
        if pricedModel != nil { return 7 }
        let completeness = breakdown?.cached != nil ? 4 : (breakdown == nil ? 0 : 2)
        return completeness + (model == nil ? 0 : 1)
    }
}

private struct UsagePriceKey: Hashable {
    let model: String
    let longContext: Bool
}

/// Resolves each rate once per scan or ranking query, including absent rates.
private final class UsageCostCalculator {
    let prices: OfficePrices
    private var rates: [UsagePriceKey: OfficeTokenPrice?] = [:]

    init(_ prices: OfficePrices) {
        self.prices = prices
    }

    func estimate(_ amounts: [UsagePriceKey: UsageBreakdown]) -> UsageEstimate {
        amounts.reduce(into: UsageEstimate()) { total, pair in
            total.add(estimate(pair.key, pair.value))
        }
    }

    func estimate(_ key: UsagePriceKey, _ breakdown: UsageBreakdown) -> UsageEstimate {
        let price: OfficeTokenPrice?
        if let cached = rates[key] {
            price = cached
        } else {
            let context = key.longContext ? OfficePrices.longContextInputThreshold + 1 : 0
            price = prices.price(model: key.model, inputTokens: context)
            rates.updateValue(price, forKey: key)
        }
        guard let price, let cached = breakdown.cached else { return UsageEstimate() }
        let cachedUSD = Double(cached) * price.cachedInput / 1_000_000
        let inputUSD = Double(breakdown.input - cached) * price.input / 1_000_000 + cachedUSD
        let outputUSD = Double(breakdown.output) * price.output / 1_000_000
        guard (inputUSD + outputUSD).isFinite, inputUSD >= 0, outputUSD >= 0, cachedUSD >= 0 else {
            return UsageEstimate()
        }
        return UsageEstimate(inputTokens: breakdown.input, outputTokens: breakdown.output, cachedTokens: cached,
                             inputUSD: inputUSD, outputUSD: outputUSD, cachedUSD: cachedUSD)
    }
}

private struct UsageBreakdown {
    private(set) var input = 0
    private(set) var output = 0
    private(set) var cached: Int?
    private(set) var cacheReportedInput = 0

    var total: Int { addingTokens(input, output) }

    init() {}

    init?(_ value: Any?, total: Int?, reasoningIncluded: Bool?) {
        guard let row = value as? OfficeJSON, let total,
              let input = usageInteger(row["input_tokens"]), input >= 0,
              let output = usageInteger(row["output_tokens"]), output >= 0 else { return nil }
        let reasoning = usageInteger(row["reasoning_output_tokens"]) ?? 0
        guard reasoning >= 0 else { return nil }
        let billedOutput: Int
        if reasoningIncluded == false || (reasoningIncluded == nil && addingTokens(input, output) != total) {
            billedOutput = addingTokens(output, reasoning)
        } else {
            billedOutput = output
        }
        guard addingTokens(input, billedOutput) == total, reasoning <= billedOutput else { return nil }
        self.input = input
        self.output = billedOutput
        if let cached = usageInteger(row["cached_input_tokens"]), (0...input).contains(cached) {
            self.cached = cached
            cacheReportedInput = input
        }
    }

    mutating func add(_ amount: Self) {
        input = addingTokens(input, amount.input)
        output = addingTokens(output, amount.output)
        if let hits = amount.cached {
            cached = addingTokens(cached ?? 0, hits)
            cacheReportedInput = addingTokens(cacheReportedInput, amount.cacheReportedInput)
        }
    }

}

private struct UsageEstimate {
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var inputUSD = 0.0
    var outputUSD = 0.0
    var cachedUSD = 0.0

    var tokens: Int { addingTokens(inputTokens, outputTokens) }
    var usd: Double { inputUSD + outputUSD }

    mutating func add(_ other: Self) {
        guard (usd + other.usd).isFinite else { return }
        inputTokens = addingTokens(inputTokens, other.inputTokens)
        outputTokens = addingTokens(outputTokens, other.outputTokens)
        cachedTokens = addingTokens(cachedTokens, other.cachedTokens)
        inputUSD += other.inputUSD
        outputUSD += other.outputUSD
        cachedUSD += other.cachedUSD
    }

    func write(to payload: inout OfficeJSON, prefix: String = "", components: Bool = false) {
        guard tokens > 0 else { return }
        payload[prefix + "estimated_usd"] = usd
        payload[prefix + "priced_tokens"] = tokens
        if components {
            payload["estimated_input_usd"] = inputUSD
            payload["estimated_output_usd"] = outputUSD
            payload["estimated_cached_input_usd"] = cachedUSD
            payload["priced_input_tokens"] = inputTokens
            payload["priced_output_tokens"] = outputTokens
            payload["priced_cached_input_tokens"] = cachedTokens
        }
    }
}

private struct QuotaReport {
    struct Window {
        let minutes: Int
        let resets: Date?
        let used: Double
        let remaining: Double

        var tracksCycle: Bool { minutes == 300 || minutes == 10_080 }
        var starts: Date? { resets?.addingTimeInterval(-Double(minutes) * 60) }
    }

    let stamp: Date
    let plan: String?
    let windows: [Window]

    init?(_ value: Any?, stamp: Date) {
        guard let data = value as? OfficeJSON, data["limit_id"] as? String == "codex" else { return nil }
        let windows: [Window] = ["primary", "secondary"].compactMap { key in
            guard let window = data[key] as? OfficeJSON,
                  let used = usageNumber(window["used_percent"])?.doubleValue, (0...100).contains(used),
                  let minutes = usageInteger(window["window_minutes"]), minutes > 0 else { return nil }
            let reset = (usageNumber(window["resets_at"])?.doubleValue).flatMap { seconds in
                seconds > 0 && seconds < 253_402_300_800 ? Date(timeIntervalSince1970: seconds) : nil
            }
            let remaining = ((100 - used) * 100).rounded(.toNearestOrEven) / 100
            return Window(minutes: minutes, resets: reset, used: used, remaining: remaining)
        }
        guard !windows.isEmpty else { return nil }
        self.stamp = stamp
        plan = data["plan_type"] as? String
        self.windows = windows.sorted { left, right in
            (left.minutes, left.resets ?? .distantPast, left.remaining) >
                (right.minutes, right.resets ?? .distantPast, right.remaining)
        }
    }
}

private struct QuotaCycleKey: Hashable {
    let minutes: Int
    let resets: Date
}

private struct QuotaSample {
    let window: QuotaReport.Window
    let resets: Date
    let stamp: Date
    let plan: String?

    // Small percentages are sensitive to rounding; 100% can include usage beyond the limit.
    var canEstimate: Bool { (5..<100).contains(window.used) }

    func planMatches(_ other: Self) -> Bool { plan == other.plan }

    func isNewer(than other: Self) -> Bool {
        (stamp, window.used) > (other.stamp, other.window.used)
    }
}

private struct QuotaCycleSamples {
    var latest: QuotaSample
    var basis: QuotaSample?

    init(_ sample: QuotaSample) {
        latest = sample
        basis = sample.canEstimate ? sample : nil
    }

    mutating func record(_ sample: QuotaSample) {
        if sample.isNewer(than: latest) { latest = sample }
        if sample.canEstimate, basis.map({ sample.isNewer(than: $0) }) ?? true { basis = sample }
    }
}

private struct QuotaCycleUsage {
    let status: String
    var observed: Int? = nil
    var estimate: Int? = nil
    var matchedTokens: Int? = nil

    func write(to payload: inout OfficeJSON) {
        payload["cycle_status"] = status
        payload["cycle_tokens"] = observed
        payload["cycle_estimated_tokens"] = estimate
    }
}

private struct UsageFile {
    private static let markers = ["session_meta", "turn_context", "token_count"].map { Data(("\"" + $0 + "\"").utf8) }

    var signature: UsageFileSignature
    var identity: String?
    var offset: UInt64 = 0
    var anchor = Data()
    var hasMetadata = false
    var created: Date?
    var workspace: String?
    var relation: UsageThreadRelation?
    var inheritsHistory = false
    private var model: String?
    private(set) var usesOpenAI = true
    private(set) var account: String?
    var entries: [UsageEvent] = []
    var quota: QuotaReport?
    var quotaCycles: [QuotaCycleKey: QuotaCycleSamples] = [:]

    init(path: URL, signature: UsageFileSignature) {
        self.signature = signature
        identity = officeRolloutID(path)
    }

    mutating func accept(_ line: Data) {
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let row = (try? JSONSerialization.jsonObject(with: line)) as? OfficeJSON,
              let payload = row["payload"] as? OfficeJSON else { return }
        let type = row["type"] as? String
        if type == "session_meta", !hasMetadata {
            hasMetadata = true
            identity = officeThreadID(payload["id"]) ?? identity
            created = officeTimestamp(payload["timestamp"]) ?? officeTimestamp(row["timestamp"])
            workspace = officeCanonicalPath(payload["cwd"]) ?? workspace
            relation = UsageThreadRelation(metadata: payload)
            let subagent = (payload["source"] as? OfficeJSON)?["subagent"]
            usesOpenAI = (payload["model_provider"] as? String).map { $0 == "openai" } ?? true
            if let id = payload["creator_account_id"] as? String, !id.isEmpty { account = id }
            model = modelName(payload["model"])
            inheritsHistory = [
                payload["forked_from_id"], payload["forked_from_session_id"], payload["parent_thread_id"], subagent,
            ].contains(where: usageTruthy)
            return
        }
        if type == "turn_context" {
            model = modelName(payload["model"])
            if workspace == nil { workspace = officeCanonicalPath(payload["cwd"]) }
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let stamp = officeTimestamp(row["timestamp"]) else { return }
        if usesOpenAI, (created.map { stamp >= $0 } ?? true), let report = QuotaReport(payload["rate_limits"], stamp: stamp) {
            if quota.map({ stamp >= $0.stamp }) ?? true { quota = report }
            if account != nil {
                // Keep two samples per observed reset rather than every token event.
                for window in report.windows where window.tracksCycle {
                    guard let resets = window.resets, let starts = window.starts, starts <= stamp, stamp < resets else { continue }
                    let key = QuotaCycleKey(minutes: window.minutes, resets: resets)
                    let sample = QuotaSample(window: window, resets: resets, stamp: stamp, plan: report.plan)
                    if quotaCycles[key] == nil { quotaCycles[key] = QuotaCycleSamples(sample) }
                    else { quotaCycles[key]?.record(sample) }
                }
            }
        }
        guard let info = payload["info"] as? OfficeJSON else { return }
        let total = usageCount(info["total_token_usage"])
        let lastUsage = info["last_token_usage"] as? OfficeJSON
        let last = usageCount(lastUsage)
        if total != nil || last != nil {
            let key = UsageEventKey(stamp: stamp, total: total, last: last)
            let breakdown = UsageBreakdown(lastUsage, total: last,
                                           reasoningIncluded: info["last_usage_includes_reasoning"] as? Bool)
            let hasCacheWrites = (usageInteger(lastUsage?["cache_write_input_tokens"]) ?? 0) != 0
            let recordedModel = modelName(payload["model"]) ?? model
            let pricedModel = usesOpenAI && !hasCacheWrites && breakdown?.cached != nil ? recordedModel : nil
            entries.append(UsageEvent(key: key, model: recordedModel, pricedModel: pricedModel, breakdown: breakdown))
        }
    }

    private func modelName(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 120, officeValidText(value, limit: 120) else { return nil }
        return value
    }
}

private struct UsageSummary {
    let signatures: [UsageFileSignature]
    let workspace: String?
    var days: [Date: Int] = [:]
    var modelDays: [Date: [String: Int]] = [:]
    var breakdownDays: [Date: UsageBreakdown] = [:]
    var priceableDays: [Date: [UsagePriceKey: UsageBreakdown]] = [:]
    var stamps: [Date] = []
    var prefix: [Int] = [0]
    var pricedEvents: [(stamp: Date, key: UsagePriceKey, breakdown: UsageBreakdown)] = []

    init(sources: [UsageFile], signatures: [UsageFileSignature], calendar: Calendar) {
        self.signatures = signatures
        let metadata = sources.first(where: \.hasMetadata)
        workspace = metadata?.workspace ?? sources.lazy.compactMap(\.workspace).first
        let forkTime = metadata?.inheritsHistory == true ? metadata?.created : nil
        var seen: [UsageEventKey: Int] = [:]
        var events: [UsageEvent] = []
        for source in sources {
            for event in source.entries {
                if let forkTime, event.key.stamp < forkTime { continue }
                if let index = seen[event.key] {
                    // Preserve token deduplication when only one copy has the full split.
                    if event.detailRank > events[index].detailRank { events[index] = event }
                } else {
                    seen[event.key] = events.count
                    events.append(event)
                }
            }
        }
        var previous: Int?
        var pending = 0
        for event in events.sorted(by: { $0.key.stamp < $1.key.stamp }) {
            let counters = event.key
            let delta: Int
            if let total = counters.total {
                if total == previous { continue }
                if let previous, total >= previous {
                    let change = total - previous
                    if change < pending { continue } // A cumulative counter can lag last-only observations.
                    delta = change - pending
                } else {
                    // A first report or reset can contain an inherited baseline.
                    if previous == nil && total < pending { continue }
                    let remaining = max(0, total - pending)
                    delta = min(counters.last ?? remaining, remaining)
                }
                previous = total
                pending = 0
            } else if let last = counters.last {
                delta = last
                pending = addingTokens(pending, last)
            } else {
                continue
            }
            if delta > 0 {
                let day = calendar.startOfDay(for: counters.stamp)
                days[day] = addingTokens(days[day, default: 0], delta)
                // Only the last request's model is known. An aggregate jump can include other models.
                let model = (counters.last == delta ? event.model : nil).map { "model:" + $0 } ?? DetailedUsageFilters.unknown
                let oldAmount = modelDays[day]?[model] ?? 0
                modelDays[day, default: [:]][model] = addingTokens(oldAmount, delta)
                stamps.append(counters.stamp)
                prefix.append(addingTokens(prefix.last ?? 0, delta))
                // A counter jump can combine requests or include a fork baseline.
                // Attribute the split only when the last request accounts for exactly the counted delta.
                if let breakdown = event.breakdown, breakdown.total == delta {
                    breakdownDays[day, default: UsageBreakdown()].add(breakdown)
                    if let model = event.pricedModel {
                        let longContext = breakdown.input > OfficePrices.longContextInputThreshold
                        let key = UsagePriceKey(model: model, longContext: longContext)
                        priceableDays[day, default: [:]][key, default: UsageBreakdown()].add(breakdown)
                        pricedEvents.append((counters.stamp, key, breakdown))
                    }
                }
            }
        }
    }

    func total(through date: Date, inclusive: Bool = true) -> Int {
        prefix[usageIndex(after: date, in: stamps, inclusive: inclusive, time: { $0 })]
    }

    func liveEstimate(after cutoff: Date, through now: Date, costs: UsageCostCalculator) -> UsageEstimate {
        let start = usageIndex(after: cutoff, in: pricedEvents, time: { $0.stamp })
        let end = usageIndex(after: now, in: pricedEvents, time: { $0.stamp })
        return pricedEvents[start..<end].reduce(into: UsageEstimate()) { total, event in
            total.add(costs.estimate(event.key, event.breakdown))
        }
    }

    private func usageIndex<Event>(after date: Date, in entries: [Event], inclusive: Bool = true, time: (Event) -> Date) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            let stamp = time(entries[mid])
            if stamp < date || (inclusive && stamp == date) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private func usageNumber(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return number
}

private func usageInteger(_ value: Any?) -> Int? {
    guard let number = usageNumber(value), !["d", "f"].contains(String(cString: number.objCType)) else {
        return nil
    }
    return number as? Int
}

private func usageCount(_ value: Any?) -> Int? {
    guard let usage = value as? OfficeJSON else { return nil }
    if let total = usageInteger(usage["total_tokens"]), total >= 0 { return total }
    guard let input = usageInteger(usage["input_tokens"]), input >= 0,
          let output = usageInteger(usage["output_tokens"]), output >= 0 else { return nil }
    return addingTokens(input, output)
}

private func addingTokens(_ first: Int, _ second: Int) -> Int {
    let (sum, overflow) = first.addingReportingOverflow(second)
    return overflow ? Int.max : sum
}

private func usageTruthy(_ value: Any?) -> Bool {
    switch value {
    case nil, is NSNull: false
    case let value as String: !value.isEmpty
    case let value as NSNumber: value.doubleValue != 0
    case let value as OfficeJSON: !value.isEmpty
    case let value as [Any]: !value.isEmpty
    default: true
    }
}

private enum UsageReadError: Error {
    case invalidFile
    case invalidArchive
}

private struct UsageLines {
    private static let maximumLine = 32 * 1024 * 1024
    private(set) var offset: UInt64
    private(set) var trailing = Data()
    private var bytesRead: UInt64
    private var oversized = false

    init(offset: UInt64) {
        self.offset = offset
        bytesRead = offset
    }

    mutating func consume(_ bytes: Data, accept: (Data) -> Void) {
        var start = bytes.startIndex
        while let end = bytes[start...].firstIndex(of: 0x0a) {
            let part = bytes[start..<end]
            if !oversized && trailing.count + part.count <= Self.maximumLine {
                if trailing.isEmpty {
                    accept(part)
                } else {
                    trailing.append(part)
                    accept(trailing)
                }
            }
            trailing.removeAll(keepingCapacity: false)
            oversized = false
            start = end + 1
            offset = bytesRead + UInt64(start - bytes.startIndex)
        }
        if !oversized {
            let remainder = bytes[start...]
            if trailing.count + remainder.count <= Self.maximumLine {
                trailing.append(remainder)
            } else {
                // A large tool result must not exhaust the app's memory.
                trailing.removeAll(keepingCapacity: false)
                oversized = true
            }
        }
        bytesRead += UInt64(bytes.count)
    }
}

private func readUsageFile(_ path: URL, signature: UsageFileSignature, previous: UsageFile?) throws -> UsageFile {
    let descriptor = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw UsageReadError.invalidFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          signature.isSameFile(as: UsageFileSignature(info)) else { throw UsageReadError.invalidFile }

    let compressed = path.pathExtension == "zst"
    var source = UsageFile(path: path, signature: signature)
    if !compressed, let previous, signature.isSameFile(as: previous.signature),
       signature.size >= previous.offset,
       signature.size > previous.signature.size || previous.offset < signature.size,
       try usageAnchor(handle, offset: previous.offset) == previous.anchor {
        source = previous
    }
    var lines = UsageLines(offset: source.offset)
    if compressed {
        try decodeArchive(handle) { data in lines.consume(data) { source.accept($0) } }
        if !lines.trailing.isEmpty { source.accept(lines.trailing) }
    } else {
        try handle.seek(toOffset: source.offset)
        var remaining = signature.size - source.offset
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(64 * 1024, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            lines.consume(chunk) { source.accept($0) }
        }
        source.offset = lines.offset
        source.anchor = try usageAnchor(handle, offset: source.offset)
    }
    source.signature = signature
    return source
}

private func usageAnchor(_ handle: FileHandle, offset: UInt64) throws -> Data {
    let length = min(offset, 512)
    try handle.seek(toOffset: 0)
    let head = try handle.read(upToCount: Int(length)) ?? Data()
    try handle.seek(toOffset: offset - length)
    let tail = try handle.read(upToCount: Int(length)) ?? Data()
    return Data(SHA256.hash(data: head + tail))
}

private func decodeArchive(_ handle: FileHandle, consume: (Data) -> Void) throws {
    guard let decoder = ZSTD_createDStream() else { throw UsageReadError.invalidArchive }
    defer { _ = ZSTD_freeDStream(decoder) }
    guard ZSTD_isError(ZSTD_initDStream(decoder)) == 0 else { throw UsageReadError.invalidArchive }
    let inputSize = ZSTD_DStreamInSize()
    let outputSize = ZSTD_DStreamOutSize()
    var outputBytes = Data(count: outputSize)
    var hint = 1
    while let chunk = try handle.read(upToCount: inputSize), !chunk.isEmpty {
        try chunk.withUnsafeBytes { inputBytes in
            var input = ZSTD_inBuffer(src: inputBytes.baseAddress, size: inputBytes.count, pos: 0)
            var emitted: Int
            repeat {
                emitted = try outputBytes.withUnsafeMutableBytes { bytes in
                    var output = ZSTD_outBuffer(dst: bytes.baseAddress, size: bytes.count, pos: 0)
                    hint = ZSTD_decompressStream(decoder, &output, &input)
                    guard ZSTD_isError(hint) == 0 else { throw UsageReadError.invalidArchive }
                    if output.pos > 0, let start = bytes.baseAddress {
                        consume(Data(bytes: start, count: output.pos))
                    }
                    return output.pos
                }
            } while input.pos < input.size || (emitted == outputSize && hint > 0)
        }
    }
    guard hint == 0 else { throw UsageReadError.invalidArchive }
}

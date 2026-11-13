import Foundation

final class ActivityProjects {
    private var paths: [String: String] = [:]
    private var overrides: [String: String?] = [:]
    private var detected: [String: String?] = [:]
    private var roots: [String] = []
    private var identifiers: [String: String] = [:]
    private let managedRoots: [String]

    init(_ settings: OfficeJSON, managedDirectories: [[String: String]] = []) {
        managedRoots = managedDirectories.compactMap { $0["path"] }
        for entry in managedDirectories {
            if let path = entry["path"], let name = entry["name"] { paths[path] = name }
        }
        for (rawPath, name) in settings["projects"] as? [String: String] ?? [:] {
            guard let path = officeCanonicalPath(rawPath) else { continue }
            paths[path] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (rawID, rawPath) in settings["thread_projects"] as? OfficeJSON ?? [:] {
            guard let thread = officeThreadID(rawID) else { continue }
            if let path = officeCanonicalPath(rawPath) {
                paths[path] = paths[path] ?? projectName(path)
                overrides.updateValue(projectID(path), forKey: thread)
            } else {
                overrides.updateValue(nil, forKey: thread)
            }
        }
    }

    func discover(_ locations: Set<String>) {
        for location in locations {
            if let root = gitRoot(location) { paths[root] = paths[root] ?? projectName(root) }
        }
        roots = paths.keys.sorted {
            let lhs = URL(fileURLWithPath: $0).pathComponents.count
            let rhs = URL(fileURLWithPath: $1).pathComponents.count
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
    }

    private func gitRoot(_ path: String) -> String? {
        if let cached = detected[path] { return cached }
        let manager = FileManager.default
        var folder = URL(fileURLWithPath: path)
        var root: String?
        while true {
            let marker = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    root = folder.path
                } else {
                    root = worktreeRoot(folder, marker: marker)
                }
                break
            }
            if folder.path == "/" || folder.path.isEmpty { break }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        detected.updateValue(root, forKey: path)
        return root
    }

    private func worktreeRoot(_ folder: URL, marker: URL) -> String? {
        guard let signature = try? ActivityFileSignature(path: marker), signature.regular,
              let file = try? FileHandle(forReadingFrom: marker) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 4096), let text = String(data: bytes, encoding: .utf8),
              let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let reference = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reference.hasPrefix("gitdir: ") else { return nil }
        let value = String(reference.dropFirst("gitdir: ".count))
        guard !value.isEmpty else { return nil }
        let path = value.hasPrefix("/") ? value : folder.path + "/" + value
        guard let gitPath = officeCanonicalPath(path) else { return nil }
        let git = URL(fileURLWithPath: gitPath)
        let worktrees = git.deletingLastPathComponent()
        let dotGit = worktrees.deletingLastPathComponent()
        if worktrees.lastPathComponent == "worktrees", dotGit.lastPathComponent == ".git" {
            return dotGit.deletingLastPathComponent().path
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? folder.path : nil
    }

    private func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func projectID(_ path: String) -> String {
        if let id = identifiers[path] { return id }
        let id = officeDigest(path, length: 24)
        identifiers[path] = id
        return id
    }

    func match(_ path: String?) -> String? {
        guard let path else { return nil }
        if let root = roots.first(where: { activityPath(path, liesIn: $0) }) { return projectID(root) }
        if let root = gitRoot(path), paths[root] != nil { return projectID(root) }
        return nil
    }

    func membership(id: String?, workspace: String?) -> String? {
        if let id, let overridden = overrides[id] { return overridden }
        return match(workspace)
    }

    func isManagedWorkspace(_ workspace: String?) -> Bool {
        guard let workspace, !managedRoots.isEmpty else { return false }
        if managedRoots.contains(where: { activityPath(workspace, liesIn: $0) }) { return true }
        guard let root = gitRoot(workspace) else { return false }
        return managedRoots.contains { activityPath(root, liesIn: $0) }
    }

    func rows() -> [OfficeJSON] {
        let projects = paths.map { path, name in (id: projectID(path), name: name) }
        return projects.sorted {
            let lhs = $0.name.folding(options: [.caseInsensitive], locale: nil)
            let rhs = $1.name.folding(options: [.caseInsensitive], locale: nil)
            return (lhs, $0.id) < (rhs, $1.id)
        }.map { ["id": $0.id, "name": $0.name] }
    }
}

/// The owning actor serializes scans and retains the file offsets and the desktop subscription.
final class CodexActivity {
    private static let recent: TimeInterval = 3 * 24 * 60 * 60
    private static let quiet: TimeInterval = 30 * 60

    let home: URL
    private let settings: OfficeSettings
    private let attentionPoll: (Set<String>) -> [String: DesktopThreadStatus]
    private var rollouts: [URL: ActivityRollout] = [:]
    private var names: [String: [String: String]] = [:]
    private var namesIDs = Set<String>()
    private var namesAt: Date?
    private var sidebarMemberships: [String: String] = [:]
    private var knownSidebarIDs = Set<String>()
    private var managedDirectories: [[String: String]] = []
    private var managedDirectoriesAt: Date?

    init(home: URL, settings: OfficeSettings,
         attentionPoll: ((Set<String>) -> [String: DesktopThreadStatus])? = nil) {
        self.home = URL(fileURLWithPath: officeCanonicalPath(home.path) ?? home.path, isDirectory: true)
        self.settings = settings
        if let attentionPoll {
            self.attentionPoll = attentionPoll
        } else {
            let attention = DesktopAttention(home: self.home)
            self.attentionPoll = { attention.poll($0) }
        }
    }

    private func readSessions(base: URL, cutoff: Date, coordinators: [String: ActivityThreadMetadata])
        -> (sources: [String: ActivityRollout], uncertain: Set<String>, hadErrors: Bool, unavailable: Bool) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let unavailable = !manager.fileExists(atPath: base.path, isDirectory: &isDirectory) || !isDirectory.boolValue
        var hadErrors = false
        var tracked: [URL: ActivityRollout] = [:]
        var sources: [String: ActivityRollout] = [:]
        var uncertain = Set<String>()
        if !unavailable, let files = manager.enumerator(at: base, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            hadErrors = true
            return true
        }) {
            for case let path as URL in files where path.pathExtension == "jsonl" {
                let prior = rollouts[path]
                let source: ActivityRollout?
                do {
                    let signature = try ActivityFileSignature(path: path)
                    guard signature.regular, signature.modified >= cutoff.timeIntervalSince1970 else { continue }
                    source = try ActivityRollout.read(path, signature: signature, previous: prior)
                } catch let error as POSIXError where error.code == .ENOENT {
                    continue
                } catch {
                    hadErrors = true
                    source = prior
                    if let id = prior?.identity { uncertain.insert(id) }
                }
                guard let source else { continue }
                tracked[path] = source
                if let id = source.identity, let last = source.last, last >= cutoff,
                   sources[id]?.last.map({ last > $0 }) ?? true {
                    sources[id] = source
                }
            }
        }
        for (id, metadata) in coordinators where sources[id] == nil {
            guard let path = officeCanonicalPath(metadata.rollout), activityPath(path, liesIn: base.path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "jsonl" else { continue }
            let source: ActivityRollout?
            if let known = tracked[url] {
                source = known
            } else {
                guard let signature = try? ActivityFileSignature(path: url), signature.regular else { continue }
                source = try? ActivityRollout.read(url, signature: signature, previous: rollouts[url])
            }
            if let source, source.identity == id, source.last != nil {
                tracked[url] = source
                sources[id] = source
            }
        }
        rollouts = tracked
        return (sources, uncertain, hadErrors, unavailable)
    }

    func scan(now: Date = Date()) -> OfficeJSON {
        let savedSettings = try? settings.load()
        let office = savedSettings ?? OfficeSettings.defaults()
        let language = (OfficeLanguage(rawValue: office["language"] as? String ?? "") ?? .simplifiedChinese).resolved
        if managedDirectoriesAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            managedDirectories = readOfficeProjectDirectories(home)
            managedDirectoriesAt = now
        }
        let projects = ActivityProjects(office, managedDirectories: managedDirectories)
        var coordination = ActivityCoordination(home: home, section: office["coordination_section"] as? String)
        let base = home.appendingPathComponent("sessions", isDirectory: true)
        let activity = readSessions(base: base, cutoff: now.addingTimeInterval(-Self.recent), coordinators: coordination.members)
        let sources = activity.sources
        let roots = Dictionary(uniqueKeysWithValues: sources.map { thread, source in
            var parent = source.parent
            var seen: Set<String> = [thread]
            while let id = parent, seen.insert(id).inserted, let ancestor = sources[id] {
                if ancestor.parent == nil { return (thread, id) }
                parent = ancestor.parent
            }
            return (thread, source.root ?? thread)
        })
        let active = Set(sources.compactMap { id, source in
            source.status == "running" && !activity.uncertain.contains(id) ? id : nil
        })
        let states = attentionPoll(active)
        let pending = Set(states.compactMap { id, state in active.contains(id) && state.waiting ? id : nil })
        var attentionTargets: [String: String] = [:]
        for id in pending.sorted() {
            let root = roots[id] ?? id
            if root == id || attentionTargets[root] == nil { attentionTargets[root] = id }
        }
        let linked = coordination.linkedThreads(sources: sources)
        let sidebarIDs = Set(sources.keys).union(linked.keys)
        var (sidebar, assignments) = readOfficeSidebar(home, threadIDs: sidebarIDs)
        sidebar["has_projects"] = !managedDirectories.isEmpty
        if sidebar["source_status"] as? String == "ok" {
            sidebarMemberships = assignments
            knownSidebarIDs = sidebarIDs
        } else {
            knownSidebarIDs.formIntersection(sidebarIDs)
            sidebarMemberships = sidebarMemberships.filter { knownSidebarIDs.contains($0.key) }
        }

        let ids = Set(sources.keys)
        if ids != namesIDs || namesAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true {
            names = activityNames(home: home, ids: ids)
            namesIDs = ids
            namesAt = now
        }
        var locations = Set(sources.values.compactMap(\.workspace))
        locations.formUnion(linked.values.compactMap { officeCanonicalPath($0.cwd) })
        for source in sources.values {
            for edit in source.edits.values { locations.formUnion(edit.locations) }
        }
        projects.discover(locations)

        var threads: [(date: Date, id: String, payload: OfficeJSON)] = []
        for (id, source) in sources {
            guard let last = source.last else { continue }
            let root = roots[id] ?? id
            let owner = sources[root] ?? source
            let origin = projects.membership(id: owner.identity, workspace: owner.workspace)
            let target = attentionTargets[id]
            var status = source.status
            if activity.uncertain.contains(id) {
                status = "unknown"
            } else if pending.contains(id) || target != nil {
                status = "waiting"
            } else if status == "running", now.timeIntervalSince(last) >= Self.quiet, states[id]?.status != "active" {
                status = "unknown"
            }
            var row: OfficeJSON = [
                "id": id,
                "project_id": (origin as Any?) ?? NSNull(),
                "sidebar_project": projects.isManagedWorkspace(owner.workspace),
                "parent_id": (source.parent as Any?) ?? NSNull(),
                "root_id": root,
                "status": status,
                "last_activity": officeISODate(last),
                "attention_thread_id": status == "waiting" ? (target ?? id) as Any : NSNull(),
                "terminal_at": (source.terminal.map(officeISODate) as Any?) ?? NSNull(),
                "token_total": (source.tokenTotal as Any?) ?? NSNull(),
                "cross_edits": source.crossEdits(projects: projects, origin: origin)
            ]
            row.merge(activityChatTitleFields(names[id] ?? [:], id: id, language: language)) { _, title in title }
            if knownSidebarIDs.contains(id) { row["section_id"] = (sidebarMemberships[id] as Any?) ?? NSNull() }
            threads.append((last, id, row))
        }
        for (id, metadata) in linked where sources[id] == nil {
            let workspace = officeCanonicalPath(metadata.cwd)
            let origin = projects.membership(id: id, workspace: workspace)
            let seconds = metadata.last ?? 0
            let last = Date(timeIntervalSince1970: (-62_135_596_800..<253_402_300_800).contains(seconds) ? seconds : 0)
            let title = metadata.name.map { ["chat_title": $0] } ?? [:]
            var row: OfficeJSON = [
                "id": id,
                "project_id": (origin as Any?) ?? NSNull(), "parent_id": NSNull(), "root_id": id,
                "sidebar_project": projects.isManagedWorkspace(workspace),
                "status": "idle", "last_activity": officeISODate(last), "terminal_at": NSNull(),
                "token_total": NSNull(), "cross_edits": []
            ]
            row.merge(activityChatTitleFields(title, id: id, language: language)) { _, title in title }
            if knownSidebarIDs.contains(id) { row["section_id"] = (sidebarMemberships[id] as Any?) ?? NSNull() }
            threads.append((last, id, row))
        }
        threads.sort { ($0.date, $0.id) > ($1.date, $1.id) }
        let status = activity.unavailable ? "unavailable" : activity.hadErrors || savedSettings == nil ? "partial" : "ok"
        return [
            "source_status": status, "collected_at": officeISODate(now), "projects": projects.rows(),
            "threads": threads.map(\.payload), "coordination": coordination.summary,
            "menu_bar_metric": office["menu_bar_metric"] ?? "token_speed",
            "sidebar": sidebar, "visible_sections": office["visible_sections"] ?? NSNull()
        ]
    }
}

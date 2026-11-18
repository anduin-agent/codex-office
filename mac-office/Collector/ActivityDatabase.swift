import Darwin
import Foundation
import SQLite3

private struct ActivityDatabaseError: Error {}

/// Open only the local state database, never create or modify it.
private final class ActivityDatabase {
    private let connection: OpaquePointer

    init(_ path: URL) throws {
        var handle: OpaquePointer?
        let result = path.withUnsafeFileSystemRepresentation {
            sqlite3_open_v2($0, &handle, SQLITE_OPEN_READONLY, nil)
        }
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ActivityDatabaseError()
        }
        connection = handle
        sqlite3_busy_timeout(handle, 150)
    }

    deinit { sqlite3_close(connection) }

    func rows(_ sql: String, _ parameters: [String] = [], visit: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ActivityDatabaseError()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            let result = parameter.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            guard result == SQLITE_OK else { throw ActivityDatabaseError() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: visit(statement)
            case SQLITE_DONE: return
            default: throw ActivityDatabaseError()
            }
        }
    }

    func columns(in table: String) throws -> Set<String> {
        var columns = Set<String>()
        try rows("PRAGMA table_info(\(table))") { row in
            if let name = databaseText(row, 1) { columns.insert(name) }
        }
        return columns
    }
}

private func databaseText(_ row: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(row, column) == SQLITE_TEXT, let buffer = sqlite3_column_text(row, column) else { return nil }
    let bytes = UnsafeBufferPointer(start: buffer, count: Int(sqlite3_column_bytes(row, column)))
    return String(bytes: bytes, encoding: .utf8)
}

private func databaseNumber(_ row: OpaquePointer, _ column: Int32) -> Double? {
    let type = sqlite3_column_type(row, column)
    guard type == SQLITE_INTEGER || type == SQLITE_FLOAT else { return nil }
    let value = sqlite3_column_double(row, column)
    return value.isFinite ? value : nil
}

private func stateDatabases(in home: URL) -> [URL] {
    [home, home.appendingPathComponent("sqlite", isDirectory: true)].flatMap { folder in
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

private func batches(_ ids: Set<String>, read: ([String], String) throws -> Void) rethrows {
    let ids = ids.sorted()
    for start in stride(from: 0, to: ids.count, by: 300) {
        let batch = Array(ids[start..<min(start + 300, ids.count)])
        try read(batch, Array(repeating: "?", count: batch.count).joined(separator: ","))
    }
}

private func displayTitle(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.unicodeScalars.prefix(240))
}

private func activityChatName(_ metadata: [String: String]) -> String? {
    if let name = metadata["chat_title"], !name.isEmpty { return name }
    let agent = metadata["agent_path"]?.split(separator: "/").last.map(String.init) ?? ""
    let labels = [agent, metadata["agent_nickname"] ?? ""].filter { !$0.isEmpty }
    return labels.isEmpty ? nil : labels.joined(separator: " · ")
}

func activityChatLabel(_ metadata: [String: String], id: String, language: OfficeLanguage) -> String {
    if let name = activityChatName(metadata) { return name }
    return activityChatFallback(metadata["thread_source"], id: id, language: language)
}

func activityChatTitleFields(_ metadata: [String: String], id: String, language: OfficeLanguage) -> OfficeJSON {
    if let name = activityChatName(metadata) { return ["title": name] }
    let source = metadata["thread_source"] ?? "chat"
    return ["title": activityChatFallback(source, id: id, language: language),
            "title_kind": ["subagent", "guardian_review"].contains(source) ? source : "chat"]
}

private func activityChatFallback(_ source: String?, id: String, language: OfficeLanguage) -> String {
    let kind = switch source {
    case "subagent": language.text("子 Agent", "Subagent")
    case "guardian_review": language.text("审查 Agent", "Review agent")
    default: language.text("Codex 会话", "Codex chat")
    }
    return kind + " · " + id.prefix(12)
}

func activityNames(home: URL, ids: Set<String>) -> [String: [String: String]] {
    guard !ids.isEmpty else { return [:] }
    var names: [String: [String: String]] = [:]
    // Use only explicit names and agent labels. The prompt-derived title is excluded.
    let fields = ["name", "agent_nickname", "agent_path", "thread_source"]
    for path in stateDatabases(in: home) {
        do {
            let database = try ActivityDatabase(path)
            let columns = try database.columns(in: "threads")
            let selected = fields.filter { columns.contains($0) }
            guard columns.contains("id"), !selected.isEmpty else { continue }
            try batches(ids) { batch, placeholders in
                let query = "SELECT id," + selected.joined(separator: ",") + " FROM threads WHERE id IN (\(placeholders))"
                try database.rows(query, batch) { row in
                    guard let id = databaseText(row, 0) else { return }
                    for (index, field) in selected.enumerated() {
                        let key = field == "name" ? "chat_title" : field
                        if names[id]?[key] == nil, let title = displayTitle(databaseText(row, Int32(index + 1))) {
                            names[id, default: [:]][key] = title
                        }
                    }
                }
            }
        } catch { continue }
    }
    if let index = try? FileHandle(forReadingFrom: home.appendingPathComponent("session_index.jsonl")) {
        defer { try? index.close() }
        var indexed: [String: String] = [:]
        var pending = Data()
        func acceptIndexLine(_ line: Data) {
            guard let item = (try? JSONSerialization.jsonObject(with: line)) as? OfficeJSON,
                  let id = item["id"] as? String, ids.contains(id),
                  let name = displayTitle(item["thread_name"] as? String) else { return }
            indexed[id] = name
        }
        while let chunk = try? index.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                acceptIndexLine(pending[start..<newline])
                start = pending.index(after: newline)
            }
            if start != pending.startIndex { pending.removeSubrange(..<start) }
        }
        if !pending.isEmpty { acceptIndexLine(pending) }
        for (id, name) in indexed where names[id]?["chat_title"] == nil {
            names[id, default: [:]]["chat_title"] = name
        }
    }
    return names
}

func usageThreadRelations(home: URL) -> (ids: Set<String>, relations: [String: UsageThreadRelation]) {
    var ids = Set<String>()
    var relations: [String: UsageThreadRelation] = [:]
    for path in stateDatabases(in: home) {
        do {
            let database = try ActivityDatabase(path)
            let columns = try database.columns(in: "threads")
            if columns.contains("id") {
                let selected = ["thread_source", "source", "attached_thread_parent_id"].filter { columns.contains($0) }
                try database.rows("SELECT " + (["id"] + selected).joined(separator: ",") + " FROM threads") { row in
                    guard let id = officeThreadID(databaseText(row, 0)) else { return }
                    ids.insert(id)
                    var metadata: OfficeJSON = [:]
                    for (index, field) in selected.enumerated() {
                        guard let value = databaseText(row, Int32(index + 1)) else { continue }
                        if field == "source" {
                            metadata[field] = try? JSONSerialization.jsonObject(with: Data(value.utf8))
                        } else if field != "attached_thread_parent_id" {
                            metadata[field] = value
                        }
                    }
                    guard var relation = UsageThreadRelation(metadata: metadata) else { return }
                    if let index = selected.firstIndex(of: "attached_thread_parent_id"),
                       let parent = officeThreadID(databaseText(row, Int32(index + 1))) {
                        relation = relation.fillingMissingFields(from: .init(kind: relation.kind, parent: parent))
                    }
                    relations[id] = relations[id]?.fillingMissingFields(from: relation) ?? relation
                }
            }
            let edges = try database.columns(in: "thread_spawn_edges")
            guard Set(["child_thread_id", "parent_thread_id"]).isSubset(of: edges) else { continue }
            try database.rows("SELECT child_thread_id,parent_thread_id FROM thread_spawn_edges") { row in
                guard let child = officeThreadID(databaseText(row, 0)), let parent = officeThreadID(databaseText(row, 1)) else { return }
                ids.insert(child)
                ids.insert(parent)
                let relation = UsageThreadRelation(kind: .subagent, parent: parent)
                relations[child] = relations[child]?.fillingMissingFields(from: relation) ?? relation
            }
        } catch { continue }
    }
    return (ids, relations)
}

/// Project placement lives in desktop preferences even when chat placement lives in SQLite.
struct OfficeSidebarProjects {
    private var signature: ActivityFileSignature?
    private var sections: [(id: String, name: String, projects: [String])] = []
    private var projectAssignments: [String: String] = [:]
    private var projectless = Set<String>()
    private var legacyIDs: [String: String] = [:]
    private var roots: [String] = []
    private var projectsByRoot: [String: Set<String>] = [:]

    mutating func refresh(_ home: URL) {
        let path = home.appendingPathComponent(".codex-global-state.json")
        let current = try? ActivityFileSignature(path: path)
        guard current != signature else { return }
        guard current?.regular == true else {
            self = Self()
            return
        }
        guard let state = readOfficeDesktopState(home) else { return }

        self = Self()
        signature = current
        let owner = state["electron-renderer-content-owner"] as? String
        let atoms = owner.flatMap { state["electron-owner-atoms:\($0)"] as? OfficeJSON }
            ?? (owner == nil ? state["electron-persisted-atom-state"] as? OfficeJSON : nil)
        let layouts = atoms?["sidebar-custom-sections-v3"] as? [String: OfficeJSON] ?? [:]
        guard layouts.count == 1, let rows = layouts.values.first?["sections"] as? [OfficeJSON],
              let localProjects = state["local-projects"] as? [String: OfficeJSON] else { return }
        let prefix = "codex:project:"
        for row in rows {
            guard let id = row["id"] as? String, officeValidSectionID(id),
                  let name = displayTitle(row["name"] as? String) else { continue }
            let projects = (row["itemKeys"] as? [String] ?? []).compactMap { key -> String? in
                guard key.hasPrefix(prefix) else { return nil }
                let project = String(key.dropFirst(prefix.count))
                return localProjects[project] == nil ? nil : project
            }
            if !projects.isEmpty { sections.append((id, name, projects)) }
        }
        guard !sections.isEmpty else { return }

        for (id, project) in localProjects {
            for value in project["rootPaths"] as? [String] ?? [] {
                if officeValidText(value, limit: 4096), let root = officeCanonicalPath(value) {
                    projectsByRoot[root, default: []].insert(id)
                }
            }
        }
        roots = projectsByRoot.keys.sorted { ($0.count, $0) > ($1.count, $1) }
        for (id, assignment) in state["thread-project-assignments"] as? [String: OfficeJSON] ?? [:] {
            if let thread = officeThreadID(id), assignment["projectKind"] as? String == "local",
               let project = assignment["projectId"] as? String {
                projectAssignments[thread] = project
            }
        }
        projectless = Set((state["projectless-thread-ids"] as? [String] ?? []).compactMap(officeThreadID))
        let migrations = state["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]]
        for (legacy, native) in migrations?["local:" + home.path] ?? [:] {
            legacyIDs[native] = legacy
        }
    }

    func appendSections(to known: inout [[String: String]]) -> [String: String] {
        let existing = Dictionary(grouping: known, by: { $0["name"] })
        let desktop = Dictionary(grouping: sections, by: \.name)
        var ids = Set(known.compactMap { $0["id"] })
        var memberships: [String: String] = [:]
        for section in sections {
            // The same desktop section can have different IDs in the two stores.
            // Keep the existing ID when the name uniquely identifies it.
            let candidates = existing[section.name] ?? []
            let match = candidates.count == 1 && desktop[section.name]?.count == 1 ? candidates.first?["id"] : nil
            let id = ids.contains(section.id) ? section.id : match ?? section.id
            if ids.insert(id).inserted { known.append(["id": id, "name": section.name]) }
            for project in section.projects where memberships[project] == nil {
                memberships[project] = id
            }
        }
        return memberships
    }

    func project(for thread: String, native: String?, workspace: String?) -> String? {
        if let native { return legacyIDs[native] ?? native }
        if projectless.contains(thread) { return nil }
        if let assigned = projectAssignments[thread] { return assigned }
        guard let workspace, let root = roots.first(where: { activityPath(workspace, liesIn: $0) }),
              let projects = projectsByRoot[root], projects.count == 1 else { return nil }
        return projects.first
    }
}

func readOfficeSidebar(_ home: URL, threadIDs: Set<String> = [], workspaces: [String: String] = [:],
                       desktopProjects: OfficeSidebarProjects? = nil) -> (OfficeJSON, [String: String]) {
    var desktop = desktopProjects ?? OfficeSidebarProjects()
    if desktopProjects == nil { desktop.refresh(home) }
    for path in stateDatabases(in: home) {
        do {
            let database = try ActivityDatabase(path)
            try database.rows("BEGIN") { _ in }
            let columns = try database.columns(in: "thread_sections")
            let threadColumns = try database.columns(in: "threads")
            guard Set(["id", "name"]).isSubset(of: columns),
                  Set(["id", "thread_section_id"]).isSubset(of: threadColumns) else { continue }
            let order = columns.contains("position") ? "position, name, id" : "name, id"
            var sections: [[String: String]] = []
            try database.rows("SELECT id,name FROM thread_sections ORDER BY \(order)") { row in
                guard let id = databaseText(row, 0), officeValidSectionID(id),
                      let name = displayTitle(databaseText(row, 1)) else { return }
                sections.append(["id": id, "name": name])
            }
            let knownSections = Set(sections.compactMap { $0["id"] })
            let projectSections = desktop.appendSections(to: &sections)
            var memberships: [String: String] = [:]
            var nativeProjects: [String: String] = [:]
            let projectColumn = !projectSections.isEmpty && threadColumns.contains("project_id") ? "project_id" : "NULL"
            try batches(threadIDs) { batch, placeholders in
                let query = "SELECT id,thread_section_id,\(projectColumn) FROM threads WHERE id IN (\(placeholders))"
                try database.rows(query, batch) { row in
                    guard let id = databaseText(row, 0) else { return }
                    if let section = databaseText(row, 1), knownSections.contains(section) { memberships[id] = section }
                    nativeProjects[id] = databaseText(row, 2)
                }
            }
            if !projectSections.isEmpty {
                for id in threadIDs where memberships[id] == nil {
                    if let project = desktop.project(for: id, native: nativeProjects[id], workspace: workspaces[id]) {
                        memberships[id] = projectSections[project]
                    }
                }
            }
            return (["source_status": "ok", "sections": sections], memberships)
        } catch { continue }
    }
    return (["source_status": "unavailable", "sections": []], [:])
}

func readOfficeProjectDirectories(_ home: URL) -> [[String: String]] {
    for path in stateDatabases(in: home) {
        do {
            let database = try ActivityDatabase(path)
            var entries: [(String?, String?)] = []
            try database.rows("""
                SELECT project_roots.path, projects.name
                FROM projects JOIN project_roots ON projects.id = project_roots.project_id
                ORDER BY projects.position, projects.id, project_roots.position
                """) { row in
                entries.append((databaseText(row, 0), databaseText(row, 1)))
            }
            return officeProjectDirectories(entries)
        } catch { continue }
    }

    // Older desktop versions registered projects in the global state file.
    guard let state = readOfficeDesktopState(home) else { return [] }

    if let projects = state["local-projects"] as? [String: OfficeJSON] {
        let order = state["project-order"] as? [String] ?? []
        let orderedIDs = Set(order)
        let ids = order + projects.keys.filter { !orderedIDs.contains($0) }.sorted()
        let entries = ids.flatMap { id -> [(String?, String?)] in
            guard let project = projects[id] else { return [] }
            let name = project["name"] as? String
            return (project["rootPaths"] as? [Any] ?? []).map { ($0 as? String, name) }
        }
        return officeProjectDirectories(entries)
    }

    let key = "electron-saved-workspace-roots"
    let paths = (state[key] as? [Any] ?? []) + state.keys.sorted()
        .filter { $0.hasPrefix("electron-owner-value:\(key):") }
        .flatMap { state[$0] as? [Any] ?? [] }
    return officeProjectDirectories(paths.map { ($0 as? String, nil) })
}

private func readOfficeDesktopState(_ home: URL) -> OfficeJSON? {
    let path = home.appendingPathComponent(".codex-global-state.json")
    let descriptor = open(path.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let limit = 32 * 1024 * 1024
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit,
          let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
    return (try? JSONSerialization.jsonObject(with: bytes)) as? OfficeJSON
}

private func officeProjectDirectories(_ entries: [(String?, String?)]) -> [[String: String]] {
    var seen = Set<String>()
    return entries.compactMap { rawPath, name in
        guard officeValidText(rawPath, limit: 4096), let path = officeCanonicalPath(rawPath),
              officeValidText(path, limit: 4096), seen.insert(path).inserted else { return nil }
        let folderName = URL(fileURLWithPath: path).lastPathComponent
        return ["path": path, "name": displayTitle(name) ?? folderName]
    }
}

struct ActivityThreadMetadata {
    let cwd: String?
    let name: String?
    let last: Double?
    let rollout: String?

    init(_ row: OpaquePointer, hasRollout: Bool) {
        cwd = databaseText(row, 1)
        name = displayTitle(databaseText(row, 2))
        last = databaseNumber(row, 3)
        rollout = hasRollout ? databaseText(row, 4) : nil
    }
}

struct ActivityCoordination {
    var summary: OfficeJSON
    var database: URL?
    var members: [String: ActivityThreadMetadata] = [:]

    init(home: URL, section: String?) {
        summary = ["section": (section as Any?) ?? NSNull(),
                   "source_status": section == nil ? "disabled" : "unavailable", "groups": []]
        guard let section else { return }
        for path in stateDatabases(in: home) {
            do {
                let database = try ActivityDatabase(path)
                var matches: [String?] = []
                try database.rows("SELECT id FROM thread_sections WHERE name=? LIMIT 2", [section]) { row in
                    matches.append(databaseText(row, 0))
                }
                guard matches.count == 1 else {
                    summary["source_status"] = matches.isEmpty ? "not_found" : "ambiguous"
                    return
                }
                var found: [String: ActivityThreadMetadata] = [:]
                if let sectionID = matches[0] {
                    try database.rows(
                        "SELECT id,cwd,name,updated_at,rollout_path FROM threads WHERE archived=0 AND thread_section_id=?",
                        [sectionID]
                    ) { row in
                        if let id = officeThreadID(databaseText(row, 0)) {
                            found[id] = ActivityThreadMetadata(row, hasRollout: true)
                        }
                    }
                }
                members = found
                summary["source_status"] = "ok"
                self.database = path
                return
            } catch { continue }
        }
    }

    mutating func linkedThreads(sources: [String: ActivityRollout]) -> [String: ActivityThreadMetadata] {
        guard let database else { return [:] }
        let coordinators = members.filter { sources[$0.key]?.parent == nil }
        let ids = Set(coordinators.keys.flatMap { id in
            (sources[id]?.dispatches.keys.map { $0 } ?? []).filter { members[$0] == nil }
        })
        var targets: [String: ActivityThreadMetadata] = [:]
        do {
            if !ids.isEmpty {
                let connection = try ActivityDatabase(database)
                try batches(ids) { batch, placeholders in
                    let query = "SELECT id,cwd,name,updated_at FROM threads WHERE archived=0 AND id IN (\(placeholders))"
                    try connection.rows(query, batch) { row in
                        guard let target = officeThreadID(databaseText(row, 0)),
                              sources[target]?.parent == nil else { return }
                        targets[target] = ActivityThreadMetadata(row, hasRollout: false)
                    }
                }
            }
        } catch {
            summary["source_status"] = "unavailable"
            return [:]
        }
        let groups: [OfficeJSON] = coordinators.keys.sorted().map { id in
            let dispatches = sources[id]?.dispatches ?? [:]
            let executors: [OfficeJSON] = dispatches
                .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
                .compactMap { target, date in
                    guard targets[target] != nil else { return nil }
                    return ["thread_id": target, "received": false, "dispatched_at": officeISODate(date)]
                }
            return ["coordinator_id": id, "executors": executors,
                    "dispatched_at": executors.last?["dispatched_at"] ?? NSNull()]
        }
        summary["groups"] = groups
        return targets.merging(coordinators) { _, coordinator in coordinator }
    }
}

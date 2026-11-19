import CoreFoundation
import Darwin
import Foundation

enum OfficeLanguage: String, Sendable {
    case simplifiedChinese = "zh-CN"
    case english = "en"
    case system

    var resolved: OfficeLanguage {
        guard self == .system else { return self }
        let languageCode = Locale.preferredLanguages.first?
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased()
        return languageCode == "zh" ? .simplifiedChinese : .english
    }

    var locale: Locale {
        Locale(identifier: resolved == .simplifiedChinese ? "zh_CN" : "en_US")
    }

    func text(_ chinese: String, _ english: String) -> String {
        resolved == .simplifiedChinese ? chinese : english
    }
}

enum OfficePipelinePreferenceChange: Sendable {
    case repository(String?)
    case authentication(repository: String, useCLI: Bool)
    case vercelProject(repository: String, project: OfficeVercelProjectLink?)
}

struct OfficePipelinePreferences: Sendable, Equatable {
    private(set) var repository: String?
    private(set) var ghRepositories: Set<String>
    private(set) var vercelProjects: [String: OfficeVercelProjectLink]

    init(_ settings: OfficeJSON?) {
        repository = settings?["pipeline_repository"] as? String
        ghRepositories = Set(settings?["pipeline_gh_repositories"] as? [String] ?? [])
        let projects = settings?["pipeline_vercel_projects"] as? [String: OfficeJSON] ?? [:]
        vercelProjects = projects.compactMapValues(Self.vercelProject)
    }

    mutating func apply(_ change: OfficePipelinePreferenceChange) {
        switch change {
        case .repository(let repository):
            self.repository = repository
        case .authentication(let repository, let useCLI):
            if useCLI { ghRepositories.insert(repository) }
            else { ghRepositories.remove(repository) }
        case .vercelProject(let repository, let project):
            vercelProjects[repository] = project
        }
    }

    var values: OfficeJSON {
        let projects: [String: OfficeJSON] = vercelProjects.mapValues { project in
            var value: OfficeJSON = ["projectId": project.projectId, "orgId": project.orgId]
            value["projectName"] = project.projectName
            return value
        }
        return ["pipeline_repository": repository as Any? ?? NSNull(), "pipeline_gh_repositories": ghRepositories.sorted(),
                "pipeline_vercel_projects": projects]
    }

    static func vercelProject(_ value: OfficeJSON) -> OfficeVercelProjectLink? {
        guard Set(value.keys).isSubset(of: ["projectId", "orgId", "projectName"]),
              let projectId = value["projectId"] as? String, let orgId = value["orgId"] as? String,
              value["projectName"] == nil || officeValidText(value["projectName"], limit: 160) else { return nil }
        let project = OfficeVercelProjectLink(projectId: projectId, orgId: orgId, projectName: value["projectName"] as? String)
        return project.valid ? project : nil
    }
}

struct OfficeSettings: Sendable {
    struct InvalidSettings: LocalizedError {
        let chinese: String
        let english: String
        var errorDescription: String? { chinese }
        init(_ chinese: String, _ english: String) {
            self.chinese = chinese
            self.english = english
        }
        func message(in language: OfficeLanguage) -> String {
            language.text(chinese, english)
        }
    }

    private static let maxBytes = 256 * 1024
    static let defaultLiveQuota = true
    static let officeZoomRange = 60...160
    static let editableKeys: Set<String> = [
        "projects", "thread_projects", "coordination_section", "menu_bar_metric", "visible_sections", "language", "live_quota",
        "office_zoom", "show_skin_desks"
    ]
    private static let storedKeys = editableKeys.union(["pipeline_repository", "pipeline_gh_repositories", "pipeline_vercel_projects"])

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Office/office.json")
    }

    let url: URL

    func preferredLanguage() -> OfficeLanguage {
        guard let value = (try? load())?["language"] as? String else { return .simplifiedChinese }
        return OfficeLanguage(rawValue: value) ?? .simplifiedChinese
    }

    static func defaults() -> OfficeJSON {
        [
            "projects": OfficeJSON(), "thread_projects": OfficeJSON(),
            "coordination_section": NSNull(), "menu_bar_metric": "token_speed", "visible_sections": NSNull(),
            "language": OfficeLanguage.simplifiedChinese.rawValue, "live_quota": defaultLiveQuota, "office_zoom": 100,
            "show_skin_desks": true
        ]
    }

    func load() throws -> OfficeJSON {
        let raw: Any
        do {
            raw = try Self.readJSON(url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return Self.defaults()
        }
        guard let document = raw as? OfficeJSON, Set(document.keys).isSubset(of: Self.storedKeys) else {
            throw InvalidSettings("办公室设置字段无效。", "The office settings contain unsupported fields.")
        }
        return try Self.validate(Self.defaults().merging(document) { _, new in new })
    }

    func update(_ changes: OfficeJSON) throws -> OfficeJSON {
        guard Set(changes.keys).isSubset(of: Self.editableKeys) else {
            throw InvalidSettings("办公室设置字段无效。", "The office settings contain unsupported fields.")
        }
        return try withLock {
            let document = try Self.validate(load().merging(changes) { _, new in new })
            try write(document)
            return document
        }
    }

    func updatePipelinePreference(_ change: OfficePipelinePreferenceChange) throws {
        try withLock {
            let document = try load()
            var preferences = OfficePipelinePreferences(document)
            preferences.apply(change)
            let updated = document.merging(preferences.values) { _, new in new }
            try write(Self.validate(updated))
        }
    }

    func importFrom(_ source: URL) throws {
        guard let document = try Self.readJSON(source) as? OfficeJSON else {
            throw InvalidSettings("此文件不包含办公室设置。", "This file does not contain office settings.")
        }
        let imported = document.filter { Self.storedKeys.contains($0.key) }
        guard !imported.isEmpty else {
            throw InvalidSettings("此文件不包含办公室设置。", "This file does not contain office settings.")
        }
        let settings = try Self.validate(Self.defaults().merging(imported) { _, new in new })
        try withLock {
            var info = stat()
            guard lstat(url.path, &info) == -1, errno == ENOENT else {
                throw InvalidSettings("办公室设置文件已存在，保留现有设置。", "An office settings file already exists and was preserved.")
            }
            try write(settings)
        }
    }

    private static func readJSON(_ url: URL) throws -> Any {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw InvalidSettings("设置必须保存在普通文件中。", "Settings must be stored in a regular file.")
        }
        guard info.st_size <= maxBytes else { throw InvalidSettings("设置文件过大。", "The settings file is too large.") }
        let raw = try file.read(upToCount: maxBytes + 1) ?? Data()
        guard raw.count <= maxBytes else { throw InvalidSettings("设置文件过大。", "The settings file is too large.") }
        do {
            return try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
        } catch {
            throw InvalidSettings("设置文件不是有效的 JSON。", "The settings file is not valid JSON.")
        }
    }

    private static func validate(_ document: OfficeJSON) throws -> OfficeJSON {
        guard let projects = document["projects"] as? OfficeJSON,
              projects.allSatisfy({ path, name in
                  officeValidText(path, limit: 4096) && officeCanonicalPath(path) != nil && officeValidText(name, limit: 80)
              }) else {
            throw InvalidSettings("项目别名须使用绝对路径和有效的显示名称。", "Project aliases need absolute paths and valid display names.")
        }
        guard let overrides = document["thread_projects"] as? OfficeJSON,
              overrides.allSatisfy({ id, path in
                  officeThreadID(id) != nil &&
                      (path is NSNull || (officeValidText(path, limit: 4096) && officeCanonicalPath(path) != nil))
              }) else {
            throw InvalidSettings("聊天归属须使用 UUID 和项目绝对路径，或填 null。", "Chat assignments need UUIDs and absolute project paths or null.")
        }
        guard document["coordination_section"] is NSNull || officeValidText(document["coordination_section"], limit: 128)
        else { throw InvalidSettings("统筹分区名称无效。", "The coordination section name is invalid.") }
        guard let metric = document["menu_bar_metric"] as? String,
              ["today_tokens", "token_speed", "plan_remaining"].contains(metric)
        else { throw InvalidSettings("菜单栏指标无效。", "The menu bar metric is invalid.") }
        guard let language = document["language"] as? String, OfficeLanguage(rawValue: language) != nil
        else { throw InvalidSettings("界面语言无效。", "The interface language is invalid.") }
        guard let liveQuota = document["live_quota"] as? NSNumber, CFGetTypeID(liveQuota) == CFBooleanGetTypeID()
        else { throw InvalidSettings("实时额度设置无效。", "Invalid live quota setting.") }
        guard let zoom = document["office_zoom"] as? Int, Self.officeZoomRange.contains(zoom)
        else { throw InvalidSettings("办公室缩放比例无效。", "Invalid office zoom.") }
        guard let showSkinDesks = document["show_skin_desks"] as? NSNumber,
              CFGetTypeID(showSkinDesks) == CFBooleanGetTypeID()
        else { throw InvalidSettings("皮肤的工位桌子设置无效。", "Invalid desk visibility for custom skins.") }
        func validRepository(_ name: String) -> Bool {
            OfficePipeline.repositoryName(name) == name && name == name.lowercased()
        }
        let cliRepositories = document["pipeline_gh_repositories"]
        let repository = document["pipeline_repository"]
        guard cliRepositories == nil || (cliRepositories as? [String])?.allSatisfy(validRepository) == true,
              repository == nil || repository is NSNull || (repository as? String).map(validRepository) == true else {
            throw InvalidSettings("CI 仓库偏好无效。", "Invalid CI repository preferences.")
        }
        if let rawProjects = document["pipeline_vercel_projects"] {
            guard let projects = rawProjects as? [String: OfficeJSON],
                  projects.allSatisfy({ validRepository($0.key) && OfficePipelinePreferences.vercelProject($0.value) != nil }) else {
                throw InvalidSettings("Vercel 项目关联无效。", "Invalid Vercel project association.")
            }
        }
        if !(document["visible_sections"] is NSNull) {
            guard let sections = document["visible_sections"] as? [Any], sections.count <= 512 else {
                throw InvalidSettings("显示分区列表无效。", "The list of visible sections is invalid.")
            }
            var unique = Set<String?>()
            for section in sections {
                guard (section is NSNull || officeValidSectionID(section)),
                      unique.insert(section as? String).inserted else {
                    throw InvalidSettings("显示分区列表无效。", "The list of visible sections is invalid.")
                }
            }
        }
        return document
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = folder.appendingPathComponent(".\(url.lastPathComponent).lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw InvalidSettings("设置锁文件无效。", "The settings lock file is invalid.")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Self.posixError() }
        }
        return try body()
    }

    private func write(_ document: OfficeJSON) throws {
        var data = try JSONSerialization.data(withJSONObject: document,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0a)
        guard data.count <= Self.maxBytes else { throw InvalidSettings("设置文件过大。", "The settings file is too large.") }
        let folder = url.deletingLastPathComponent()
        var temporary = Array(folder.appendingPathComponent(".\(url.lastPathComponent).XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&temporary)
        guard descriptor >= 0 else { throw Self.posixError() }
        defer {
            close(descriptor)
            unlink(temporary)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try file.write(contentsOf: data)
        try file.synchronize()
        guard rename(temporary, url.path) == 0 else { throw Self.posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

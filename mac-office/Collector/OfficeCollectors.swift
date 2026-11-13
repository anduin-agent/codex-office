import Foundation

enum OfficeCollectorPaths {
    static func codexHome(_ override: String? = nil) -> URL {
        if let path = override ?? ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return fileURL(path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func settings(_ override: String? = nil) -> OfficeSettings {
        OfficeSettings(url: override.map(fileURL) ?? OfficeSettings.defaultURL)
    }

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

/// The collectors have separate executors so indexing archives cannot delay live activity or settings.
actor OfficeActivityCollector {
    private let home: URL
    private let settings: OfficeSettings
    private let activity: CodexActivity

    init(home: URL, settings: OfficeSettings) {
        self.home = home
        self.settings = settings
        activity = CodexActivity(home: home, settings: settings)
    }

    func snapshot() throws -> Data {
        try Task.checkCancellation()
        return try JSONSerialization.data(withJSONObject: activity.scan())
    }

    func projectDirectories() -> [[String: String]] {
        readOfficeProjectDirectories(home)
    }

    func officeSettings(changes: Data?) throws -> Data {
        try Task.checkCancellation()
        let document: OfficeJSON
        if let changes {
            guard let updates = try JSONSerialization.jsonObject(with: changes) as? OfficeJSON else {
                throw OfficeSettings.InvalidSettings("办公室设置字段无效。", "The office settings contain unsupported fields.")
            }
            document = try settings.update(updates)
        } else {
            document = try settings.load()
        }
        let (sidebar, _) = readOfficeSidebar(home)
        return try JSONSerialization.data(withJSONObject: ["office": document, "sidebar": sidebar])
    }
}

actor OfficeUsageCollector {
    private let usage: CodexTokenUsage
    private let prices: OfficePriceCache
    private let settings: OfficeSettings

    init(home: URL, prices: OfficePriceCache, settings: OfficeSettings) {
        usage = CodexTokenUsage(home: home)
        self.prices = prices
        self.settings = settings
    }

    func snapshot(refreshPrices: Bool) async throws -> Data {
        let rates = await prices.prices(refresh: refreshPrices)
        try Task.checkCancellation()
        return try JSONSerialization.data(withJSONObject: usage.scan(prices: rates))
    }

    func dayDetails(_ day: String, language: OfficeLanguage) throws -> Data {
        try Task.checkCancellation()
        return try JSONSerialization.data(withJSONObject: usage.dayDetails(day, language: language))
    }

    func detailedUsage(_ data: Data, language: OfficeLanguage) throws -> Data {
        try Task.checkCancellation()
        let query = try JSONSerialization.jsonObject(with: data) as? OfficeJSON ?? [:]
        return try JSONSerialization.data(withJSONObject: usage.detailedUsage(query, language: language, settings: settings))
    }
}

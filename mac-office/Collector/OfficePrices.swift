import Foundation

struct OfficeTokenPrice: Codable, Sendable {
    // USD per million tokens.
    let input: Double
    let cachedInput: Double
    let output: Double
    let cacheWriteInput: Double?

    init(input: Double, cachedInput: Double, output: Double, cacheWriteInput: Double? = nil) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.cacheWriteInput = cacheWriteInput
    }

    fileprivate var isValid: Bool {
        input.isFinite && input > 0 && output.isFinite && output > 0 &&
            cachedInput.isFinite && (0...input).contains(cachedInput) &&
            (cacheWriteInput.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

struct OfficePrices: Codable, Sendable {
    let updatedAt: String
    private let rates: [String: OfficeTokenPrice]
    private let longContext: [String: OfficeTokenPrice]

    static let longContextInputThreshold = 272_000
    static let empty = Self(updatedAt: "", rates: [:])

    init(updatedAt: String, rates: [String: OfficeTokenPrice], longContext: [String: OfficeTokenPrice] = [:]) {
        self.updatedAt = updatedAt
        self.rates = rates
        self.longContext = longContext
    }

    static func load(from url: URL?) -> Self {
        guard let url, let data = try? Data(contentsOf: url),
              let prices = try? JSONDecoder().decode(Self.self, from: data), prices.isValid else {
            return .empty
        }
        return prices
    }

    func price(model: String, inputTokens: Int = 0) -> OfficeTokenPrice? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifier: String
        if rates[name] != nil {
            identifier = name
        } else if let date = name.range(of: #"-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) {
            identifier = String(name[..<date.lowerBound])
        } else {
            return nil
        }
        if inputTokens > Self.longContextInputThreshold, let rate = longContext[identifier] {
            return rate
        }
        return rates[identifier]
    }

    fileprivate var isValid: Bool {
        if rates.isEmpty {
            return updatedAt.isEmpty && longContext.isEmpty
        }
        return updatedAt.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil &&
            rates.values.allSatisfy(\.isValid) &&
            longContext.allSatisfy { rates[$0.key] != nil && $0.value.isValid }
    }

    fileprivate func merging(_ newer: Self) -> Self {
        Self(
            updatedAt: max(updatedAt, newer.updatedAt),
            rates: rates.merging(newer.rates) { _, new in new },
            longContext: longContext.merging(newer.longContext) { _, new in new }
        )
    }

    static func parseOfficial(_ markdown: String, updatedAt: String) -> Self? {
        var rates: [String: OfficeTokenPrice] = [:]
        var longContext: [String: OfficeTokenPrice] = [:]
        var columns: [String] = []
        var isStandard = false
        var isStandardTable = false
        var isCodexTable = false

        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            switch line {
            case "standard":
                isStandard = true
            case "batch", "flex", "fast", "ultrafast":
                isStandard = false
                isStandardTable = false
                isCodexTable = false
            case let heading where heading.hasPrefix("### "):
                isStandardTable = heading == "### standard pricing data"
                isCodexTable = isStandard && heading == "### grouped pricing table data"
                columns = []
            default:
                guard (isStandardTable || isCodexTable), line.hasPrefix("|"), line.hasSuffix("|") else {
                    continue
                }
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.contains("model") {
                    columns = cells
                    continue
                }
                guard cells.count == columns.count, let modelColumn = columns.firstIndex(of: "model") else {
                    continue
                }
                if isCodexTable {
                    guard let category = columns.firstIndex(of: "category"), cells[category] == "codex" else {
                        continue
                    }
                }
                let shortContextLabel = " (<272k context length)"
                let label = cells[modelColumn]
                let model = label.hasSuffix(shortContextLabel) ? String(label.dropLast(shortContextLabel.count)) : label
                guard model.range(of: #"^(gpt-[a-z0-9.-]+|o[134](?:-[a-z0-9.-]+)?)$"#,
                                  options: .regularExpression) != nil else { continue }
                let shortPrefix = columns.contains("short context input") ? "short context " : ""
                guard let rate = tablePrice(cells, columns: columns, prefix: shortPrefix) else { continue }
                rates[model] = rate
                if let long = tablePrice(cells, columns: columns, prefix: "long context ") {
                    longContext[model] = long
                }
            }
        }

        // Keep the last usable table if the published layout stops matching these sections.
        guard rates.count >= 5, !longContext.isEmpty else { return nil }
        let prices = Self(updatedAt: updatedAt, rates: rates, longContext: longContext)
        return prices.isValid ? prices : nil
    }

    private static func tablePrice(_ cells: [String], columns: [String], prefix: String) -> OfficeTokenPrice? {
        func dollars(_ name: String) -> Double? {
            guard let column = columns.firstIndex(of: prefix + name), cells[column].hasPrefix("$") else {
                return nil
            }
            return Double(cells[column].dropFirst())
        }
        guard let input = dollars("input"), let cached = dollars("cached input"),
              let output = dollars("output") else { return nil }
        let rate = OfficeTokenPrice(input: input, cachedInput: cached, output: output)
        return rate.isValid ? rate : nil
    }
}

actor OfficePriceCache {
    private struct Record: Codable {
        var lastAttempt: Date?
        var prices: OfficePrices
    }

    private static let source = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    private let cacheURL: URL?
    private let loadMarkdown: @Sendable () async -> String?
    private var record: Record
    private var refreshing = false

    init(seedURL: URL?, cacheURL: URL?, loadMarkdown: (@Sendable () async -> String?)? = nil) {
        self.cacheURL = cacheURL
        self.loadMarkdown = loadMarkdown ?? Self.fetchMarkdown
        let seed = OfficePrices.load(from: seedURL)
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(Record.self, from: data), cached.prices.isValid {
            let prices = seed.updatedAt > cached.prices.updatedAt ? cached.prices.merging(seed) : seed.merging(cached.prices)
            record = Record(lastAttempt: cached.lastAttempt, prices: prices)
        } else {
            record = Record(lastAttempt: nil, prices: seed)
        }
    }

    func prices(refresh: Bool = true) async -> OfficePrices {
        let now = Date()
        if refresh, let cacheURL, !refreshing,
           record.lastAttempt.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) ?? true {
            record.lastAttempt = now
            refreshing = true
            Task { await refreshPrices(cacheURL: cacheURL, attemptedAt: now) }
        }
        return record.prices
    }

    private func refreshPrices(cacheURL: URL, attemptedAt: Date) async {
        defer { refreshing = false }
        // Persist the attempt before going online so restarting after a failure does not retry today.
        guard persist(record, to: cacheURL), let markdown = await loadMarkdown() else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        guard let updated = OfficePrices.parseOfficial(markdown, updatedAt: formatter.string(from: attemptedAt)) else {
            return
        }
        let refreshed = Record(lastAttempt: attemptedAt, prices: record.prices.merging(updated))
        if persist(refreshed, to: cacheURL) {
            record = refreshed
        }
    }

    private func persist(_ record: Record, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func fetchMarkdown() async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData)
        let limit = 512 * 1024
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoPriceRedirects())
            guard let http = response as? HTTPURLResponse, http.url == source, http.statusCode == 200,
                  http.expectedContentLength <= limit else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { return nil }
                data.append(byte)
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

private final class NoPriceRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

import Foundation

struct OfficeReleaseCheck {
    enum Result: String {
        case noRelease, current, available, failed
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private let endpoint: URL
    let releasesPage: URL

    init?(repository: String?) {
        guard let repository, repository.utf8.count <= 140,
              repository.range(of: #"\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*\z"#,
                               options: .regularExpression) != nil,
              let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest"),
              let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest") else { return nil }
        self.endpoint = endpoint
        self.releasesPage = releasesPage
    }

    func check(currentVersion: String) async -> (Result, String?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == endpoint else { return (.failed, nil) }
            if http.statusCode == 404 { return (.noRelease, nil) }
            let limit = 512 * 1024
            guard http.statusCode == 200, http.expectedContentLength <= limit else { return (.failed, nil) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { return (.failed, nil) }
                data.append(byte)
            }
            return Self.compare(currentVersion: currentVersion, releaseData: data)
        } catch {
            return (.failed, nil)
        }
    }

    static func compare(currentVersion: String, releaseData: Data) -> (Result, String?) {
        guard let release = try? JSONDecoder().decode(Release.self, from: releaseData),
              !release.draft, !release.prerelease,
              let current = version(currentVersion), let latest = version(release.tag_name) else { return (.failed, nil) }
        return (current.lexicographicallyPrecedes(latest) ? .available : .current,
                latest.map(String.init).joined(separator: "."))
    }

    private static func version(_ tag: String) -> [Int]? {
        let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        return values.count == parts.count ? values : nil
    }
}

import Darwin
import Foundation

struct OfficePipelineRun: Codable, Sendable {
    let id: Int
    let workflowID: Int?
    let attempt: Int
    let name: String
    let state: String
    let branch: String?
    let commit: String?
    let number: Int?
    let triggeredAt: String?
    let updated: String?
}

struct OfficePipelineJob: Codable, Sendable {
    struct Step: Codable, Sendable {
        let name: String
        let state: String
    }

    let name: String
    let state: String
    let steps: [Step]
}

struct OfficePipelineSnapshot: Encodable, Sendable {
    var repository: String?
    var sha: String?
    var runs: [OfficePipelineRun] = []
    var latestRunID: Int?
    var runID: Int?
    var jobs: [OfficePipelineJob] = []
    var releases: [OfficeDeploymentSnapshot] = []
    var actionsError: String?
    var jobsError: String?
    var actionsCheckedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case repository, sha, runs, latestRunID, runID, jobs, releases, actionsError, jobsError
    }

    mutating func keepPreviousActions(_ previous: Self, selectedRun: Int?) {
        if actionsError != nil {
            runs = previous.runs
            latestRunID = previous.latestRunID
            runID = previous.runID
            jobsError = actionsError
        }
        if jobsError != nil, let runID, runID == previous.runID, selectedRun == nil || selectedRun == runID,
           runs.first(where: { $0.id == runID })?.attempt == previous.runs.first(where: { $0.id == runID })?.attempt {
            jobs = previous.jobs
        }
    }

    func link(source: String, index: Int, releaseIndex: Int?) -> URL? {
        if source == "actions", let repository, runs.indices.contains(index) {
            let run = runs[index]
            return URL(string: "https://github.com/\(repository)/actions/runs/\(run.id)/attempts/\(run.attempt)")
        }
        guard let releaseIndex, releases.indices.contains(releaseIndex), releases[releaseIndex].provider == source else { return nil }
        return releases[releaseIndex].link(at: index)
    }
}

private enum OfficePipelineError: String, Error {
    case unavailable, inaccessible, rateLimited, cliMissing, cliUnavailable
}

actor OfficePipeline {
    typealias Fetch = @Sendable (String, Bool) async throws -> Data
    private let fetch: Fetch?
    private let deploymentProviders: [any OfficeDeploymentProvider]
    private var publicRetryAfter: Date?

    init(fetch: Fetch? = nil, deploymentProviders: [any OfficeDeploymentProvider] = [OfficeVercelDeployments()]) {
        self.fetch = fetch
        self.deploymentProviders = deploymentProviders
    }

    func deploymentSnapshot(workspace: String?, vercelProjects: [String: OfficeVercelProjectLink],
                            previous: OfficePipelineSnapshot?, automatic: Bool) async -> OfficePipelineSnapshot {
        guard let workspace, let target = await OfficePipelineWorkspace.resolve(workspace), !Task.isCancelled else {
            return OfficePipelineSnapshot()
        }
        let project = target.repository.flatMap { vercelProjects[$0] }
        let releases = await Self.readDeployments(deploymentProviders, target: target, vercelProject: project,
                                                  previous: previous?.releases ?? [],
                                                  automatic: automatic)
        return OfficePipelineSnapshot(sha: target.sha, releases: releases)
    }

    private static func readDeployments(_ providers: [any OfficeDeploymentProvider], target: OfficePipelineWorkspace,
                                        vercelProject: OfficeVercelProjectLink?,
                                        previous: [OfficeDeploymentSnapshot],
                                        automatic: Bool) async -> [OfficeDeploymentSnapshot] {
        var releases: [OfficeDeploymentSnapshot] = []
        for provider in providers where !Task.isCancelled {
            let project = provider.id == "vercel" ? vercelProject : nil
            var release = await provider.deployments(in: target, project: project, previous: previous.first { $0.provider == provider.id },
                                                    automatic: automatic)
            if release.error != nil, let binding = release.binding,
               let old = previous.first(where: { $0.provider == release.provider && $0.binding == binding }) {
                release.records = old.records
                release.project = old.project ?? release.project
            }
            releases.append(release)
        }
        return releases
    }

    func repositorySnapshot(repository: String, workspaces: [OfficePipelineWorkspace], vercelProject: OfficeVercelProjectLink?,
                            useCLI: Bool, selectedRun: Int?,
                            previous: OfficePipelineSnapshot?, automatic: Bool) async -> OfficePipelineSnapshot {
        var result: OfficePipelineSnapshot
        if automatic, !useCLI, let previous, let checked = previous.actionsCheckedAt, Date().timeIntervalSince(checked) < 150 {
            result = previous
        } else {
            result = await readActions(repository: repository, useCLI: useCLI, selectedRun: selectedRun)
            if let previous { result.keepPreviousActions(previous, selectedRun: selectedRun) }
        }
        let sha = result.runs.first { $0.id == result.latestRunID }?.commit
        result.sha = sha
        result.releases = []
        let oldReleases = previous?.sha == sha ? previous?.releases ?? [] : []
        for provider in deploymentProviders where !Task.isCancelled {
            let previous = oldReleases.filter { $0.provider == provider.id }
            let project = provider.id == "vercel" ? vercelProject : nil
            let releases = await provider.deployments(in: workspaces, project: project, commit: sha,
                                                      previous: previous, automatic: automatic)
            result.releases.append(contentsOf: releases)
        }
        return result
    }

    private func readActions(repository: String, useCLI: Bool, selectedRun: Int?) async -> OfficePipelineSnapshot {
        let path = "repos/\(repository)"
        var result = OfficePipelineSnapshot(repository: repository, actionsCheckedAt: Date())
        do {
            let runs: RunList = try await get("\(path)/actions/runs?per_page=8", useCLI: useCLI)
            result.runs = runs.workflow_runs.prefix(8).filter { $0.id > 0 }.map { run in
                let attempt = max(run.run_attempt ?? 1, 1)
                let created = officeTimestamp(run.created_at)
                let started = officeTimestamp(run.run_started_at)
                let triggered = attempt > 1 ? [created, started].compactMap { $0 }.max() : created ?? started
                return OfficePipelineRun(id: run.id, workflowID: run.workflow_id, attempt: attempt,
                                         name: Self.label(run.name), state: Self.state(run.status, conclusion: run.conclusion),
                                         branch: run.head_branch.map(Self.label), commit: run.head_sha.flatMap(Self.commitSHA),
                                         number: run.run_number, triggeredAt: triggered.map(officeISODate), updated: run.updated_at)
            }.sorted {
                ($0.triggeredAt ?? "") > ($1.triggeredAt ?? "")
            }
        } catch {
            result.actionsError = Self.errorCode(error)
        }
        result.latestRunID = result.runs.first?.id
        if let run = result.runs.first(where: { $0.id == selectedRun }) ?? result.runs.first {
            result.runID = run.id
            do {
                let jobs: JobList = try await get("\(path)/actions/runs/\(run.id)/attempts/\(run.attempt)/jobs?per_page=30",
                                                  useCLI: useCLI)
                result.jobs = jobs.jobs.map { job in
                    OfficePipelineJob(name: Self.label(job.name), state: Self.state(job.status, conclusion: job.conclusion),
                                      steps: (job.steps ?? []).prefix(100).map {
                                          .init(name: Self.label($0.name), state: Self.state($0.status, conclusion: $0.conclusion))
                                      })
                }
            } catch {
                result.jobsError = Self.errorCode(error)
            }
        }
        return result
    }

    private static func commitSHA(_ value: String) -> String? {
        value.range(of: #"\A[0-9a-fA-F]{40}\z"#, options: .regularExpression) == nil ? nil : value.lowercased()
    }

    private static func state(_ status: String, conclusion: String?) -> String {
        status == "completed" ? conclusion ?? status : status
    }

    static func repository(from value: String) -> String? {
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else {
            guard let url = URLComponents(string: value), url.host?.lowercased() == "github.com",
                  url.query == nil, url.fragment == nil, url.port == nil,
                  (url.scheme == "https" && url.user == nil && url.password == nil ||
                   url.scheme == "ssh" && url.user == "git" && url.password == nil) else { return nil }
            path = String(url.percentEncodedPath.dropFirst())
        }
        return repositoryName(path.hasSuffix(".git") ? String(path.dropLast(4)) : path)
    }

    static func repositoryName(_ repository: String) -> String? {
        guard repository.range(of: #"\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}\z"#,
                                options: .regularExpression) != nil,
              !repository.hasSuffix("/."), !repository.hasSuffix("/..") else { return nil }
        return repository
    }

    private func get<T: Decodable>(_ endpoint: String, useCLI: Bool) async throws -> T {
        try Task.checkCancellation()
        let data: Data
        if let fetch {
            data = try await fetch(endpoint, useCLI)
        } else if useCLI {
            data = try await Self.cliGET(endpoint)
        } else {
            data = try await publicGET(endpoint)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func cliGET(_ endpoint: String) async throws -> Data {
        guard let gh = OfficePipelineCommand.installed("gh") else { throw OfficePipelineError.cliMissing }
        let task = Task.detached(priority: .utility) {
            OfficePipelineCommand.read(gh, ["api", "--hostname", "github.com", "--method", "GET", endpoint])
        }
        guard let data = await withTaskCancellationHandler(operation: { await task.value },
                                                          onCancel: { task.cancel() }) else {
            throw OfficePipelineError.cliUnavailable
        }
        return data
    }

    private func publicGET(_ endpoint: String) async throws -> Data {
        if let publicRetryAfter, publicRetryAfter > Date() { throw OfficePipelineError.rateLimited }
        guard let url = URL(string: "https://api.github.com/\(endpoint)") else { throw OfficePipelineError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: OfficePipelineNoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Codex-Office", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OfficePipelineError.unavailable }
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        if remaining == "0", let reset, reset.isFinite {
            publicRetryAfter = Date(timeIntervalSince1970: reset)
        }
        if response.statusCode == 429 || response.statusCode == 403 && (remaining == "0" || retry != nil) {
            if let retry, retry.isFinite, retry > 0 {
                publicRetryAfter = max(publicRetryAfter ?? .distantPast, Date().addingTimeInterval(retry))
            } else if (publicRetryAfter ?? .distantPast) <= Date() {
                publicRetryAfter = Date().addingTimeInterval(60)
            }
            throw OfficePipelineError.rateLimited
        }
        if [401, 403, 404].contains(response.statusCode) { throw OfficePipelineError.inaccessible }
        guard response.statusCode == 200, data.count <= OfficePipelineCommand.outputLimit else {
            throw OfficePipelineError.unavailable
        }
        return data
    }

    private static func errorCode(_ error: Error) -> String {
        (error as? OfficePipelineError ?? .unavailable).rawValue
    }

    static func label(_ value: String) -> String {
        String(value.prefix(180)).filter { !$0.isNewline && !$0.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        } }
    }

    private struct RunList: Decodable {
        struct Run: Decodable {
            let id: Int
            let workflow_id: Int?
            let name: String
            let head_sha: String?
            let head_branch: String?
            let status: String
            let conclusion: String?
            let run_attempt: Int?
            let run_number: Int?
            let created_at: String?
            let run_started_at: String?
            let updated_at: String?
        }

        let workflow_runs: [Run]
    }

    private struct JobList: Decodable {
        struct Job: Decodable {
            struct Step: Decodable {
                let name: String
                let status: String
                let conclusion: String?
            }

            let name: String
            let status: String
            let conclusion: String?
            let steps: [Step]?
        }

        let jobs: [Job]
    }

}

private final class OfficePipelineNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum OfficePipelineCommand {
    static let outputLimit = 4 * 1_048_576

    static func installed(_ executable: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home.appendingPathComponent(".local/bin").path]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        // The system Git shim can open an installation prompt when developer tools are absent.
        guard executable == "git",
              read(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]) != nil else { return nil }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    static func read(_ executable: URL, _ arguments: [String], includeStderr: Bool = false) -> Data? {
        guard !Task.isCancelled else { return nil }
        let process = Process()
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let home = FileManager.default.homeDirectoryForCurrentUser
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = home
        var environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:"
                + home.appendingPathComponent(".local/bin").path,
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
            "GH_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1",
        ]
        if executable.lastPathComponent == "vercel" {
            environment["CI"] = "1"
            environment["VERCEL_TELEMETRY_DISABLED"] = "1"
            environment["DO_NOT_TRACK"] = "1"
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = includeStderr ? pipe : FileHandle.nullDevice
        defer {
            try? reader.close()
            if process.isRunning { process.terminate() }
        }
        do { try process.run() } catch { return nil }

        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var data = Data()
        var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
            if count == 0 {
                while process.isRunning && !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return !process.isRunning && process.terminationStatus == 0 ? data : nil
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= outputLimit else { return nil }
            data.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }
}

import Foundation

struct OfficePipelineWorkspace: Sendable {
    let directory: URL
    var gitRoot: URL?
    var sha: String?
    var repository: String?

    static func repositories(in paths: [String]) async -> [String: [Self]] {
        let task = Task.detached(priority: .utility) {
            guard let git = OfficePipelineCommand.installed("git") else { return [String: [Self]]() }
            var repositories: [String: [Self]] = [:]
            for path in paths where !Task.isCancelled {
                if let remote = gitOutput(git, at: path, ["config", "--local", "--no-includes", "--get", "remote.origin.url"]),
                   let repository = OfficePipeline.repository(from: remote) {
                    let root = gitOutput(git, at: path, ["rev-parse", "--show-toplevel"])
                        .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
                    let workspace = Self(directory: URL(fileURLWithPath: path, isDirectory: true), gitRoot: root)
                    repositories[repository.lowercased(), default: []].append(workspace)
                }
            }
            return repositories
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func gitOutput(_ git: URL, at path: String, _ command: [String]) -> String? {
        OfficePipelineCommand.read(git, ["-C", path, "--no-optional-locks"] + command).map {
            String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
    }

    static func resolve(_ workspace: String) async -> Self? {
        let task = Task.detached(priority: .utility) { () -> Self? in
            guard let path = officeCanonicalPath(workspace) else { return nil }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            var target = Self(directory: directory)
            guard let git = OfficePipelineCommand.installed("git") else { return target }
            if let root = gitOutput(git, at: path, ["rev-parse", "--show-toplevel"]), root.hasPrefix("/") {
                target.gitRoot = URL(fileURLWithPath: root, isDirectory: true)
            }
            if let head = gitOutput(git, at: path, ["rev-parse", "--verify", "HEAD"]),
               head.range(of: #"\A[0-9a-f]{40}\z"#, options: .regularExpression) != nil {
                target.sha = head
            }
            target.repository = gitOutput(git, at: path, ["config", "--local", "--no-includes", "--get", "remote.origin.url"])
                .flatMap(OfficePipeline.repository(from:))?.lowercased()
            return target
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

struct OfficeVercelProjectLink: Codable, Sendable, Equatable {
    let projectId: String
    let orgId: String
    let projectName: String?

    init(projectId: String, orgId: String, projectName: String? = nil) {
        self.projectId = projectId
        self.orgId = orgId
        self.projectName = projectName
    }

    var binding: String { "\(orgId)/\(projectId)" }

    var valid: Bool {
        projectId.range(of: #"\Aprj_[A-Za-z0-9_-]{1,120}\z"#, options: .regularExpression) != nil &&
            (orgId.isEmpty || orgId.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil)
    }
}

protocol OfficeDeploymentProvider: Sendable {
    var id: String { get }
    func deployments(in workspace: OfficePipelineWorkspace, project: OfficeVercelProjectLink?, previous: OfficeDeploymentSnapshot?,
                     automatic: Bool) async -> OfficeDeploymentSnapshot
    func deployments(in workspaces: [OfficePipelineWorkspace], project: OfficeVercelProjectLink?, commit: String?, previous: [OfficeDeploymentSnapshot],
                     automatic: Bool) async -> [OfficeDeploymentSnapshot]
}

extension OfficeDeploymentProvider {
    func deployments(in workspace: OfficePipelineWorkspace, previous: OfficeDeploymentSnapshot?,
                     automatic: Bool) async -> OfficeDeploymentSnapshot {
        await deployments(in: workspace, project: nil, previous: previous, automatic: automatic)
    }

    func deployments(in workspaces: [OfficePipelineWorkspace], project: OfficeVercelProjectLink?, commit: String?, previous: [OfficeDeploymentSnapshot],
                     automatic: Bool) async -> [OfficeDeploymentSnapshot] {
        []
    }
}

struct OfficeDeploymentSnapshot: Encodable, Sendable {
    let provider: String
    var binding: String?
    var project: String?
    var checkedAt: Date?
    var records: [OfficeDeploymentRecord] = []
    var isLatestFallback: Bool = false
    var error: String?

    private enum CodingKeys: String, CodingKey {
        case provider, project, records, isLatestFallback, error
    }

    func link(at index: Int) -> URL? {
        records.indices.contains(index) ? records[index].url : nil
    }
}

struct OfficeDeploymentRecord: Encodable, Sendable {
    let environment: String
    let state: String
    let release: String?
    let branch: String?
    let commit: String?
    let observedAt: String?
    let errorCode: String?
    let url: URL?
    let canOpen: Bool

    init(environment: String, state: String, release: String?, branch: String?, commit: String?,
         observedAt: String?, errorCode: String?, url: URL?) {
        self.environment = environment
        self.state = state
        self.release = release
        self.branch = branch
        self.commit = commit
        self.observedAt = observedAt
        self.errorCode = errorCode
        self.url = url
        self.canOpen = url != nil
    }

    private enum CodingKeys: String, CodingKey {
        case environment, state, release, branch, commit, observedAt, errorCode, canOpen
    }
}

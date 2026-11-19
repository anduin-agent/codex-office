import Foundation

struct OfficeVercelDeployments: OfficeDeploymentProvider {
    typealias Fetch = @Sendable (String) async throws -> Data
    let id = "vercel"
    var fetch: Fetch?

    func deployments(in workspace: OfficePipelineWorkspace, project: OfficeVercelProjectLink?, previous: OfficeDeploymentSnapshot?,
                     automatic: Bool) async -> OfficeDeploymentSnapshot {
        guard let link = project ?? Self.link(in: workspace), link.valid else {
            return OfficeDeploymentSnapshot(provider: id, error: "unlinked")
        }
        return await load(link, commit: nil, previous: previous, automatic: automatic)
    }

    func deployments(in workspaces: [OfficePipelineWorkspace], project: OfficeVercelProjectLink?, commit: String?, previous: [OfficeDeploymentSnapshot],
                     automatic: Bool) async -> [OfficeDeploymentSnapshot] {
        let links: [OfficeVercelProjectLink]
        if let project {
            guard project.valid else { return [OfficeDeploymentSnapshot(provider: id, error: "unlinked")] }
            links = [project]
        } else {
            links = workspaces.flatMap(Self.repositoryLinks)
        }
        var seen = Set<String>()
        var releases: [OfficeDeploymentSnapshot] = []
        for link in links where !Task.isCancelled && seen.insert(link.binding).inserted {
            let old = previous.first { $0.provider == id && $0.binding == link.binding }
            var release = await load(link, commit: commit, previous: old, automatic: automatic,
                                     useLatestFallback: true)
            if release.error != nil, let old {
                release.records = old.records
                release.project = old.project ?? release.project
                release.isLatestFallback = old.isLatestFallback
            }
            releases.append(release)
        }
        return releases
    }

    private func load(_ link: OfficeVercelProjectLink, commit: String?, previous: OfficeDeploymentSnapshot?,
                      automatic: Bool, useLatestFallback: Bool = false) async -> OfficeDeploymentSnapshot {
        let binding = link.binding
        if automatic, let previous, previous.binding == binding, previous.error != nil,
           let checked = previous.checkedAt, Date().timeIntervalSince(checked) < 180 {
            return previous
        }
        var result = OfficeDeploymentSnapshot(provider: id, binding: binding,
                                              project: link.projectName.map(OfficePipeline.label), checkedAt: Date())
        do {
            let sha = commit.flatMap(Self.normalizedSHA)
            if commit != nil && sha == nil { throw ReadError.unavailable }
            var deployments = try await read(link, commit: sha, limit: useLatestFallback && sha == nil ? 1 : 10)
            var records = deployments.map(\.record).filter { sha == nil || $0.commit == sha }
            if useLatestFallback {
                if sha != nil && records.isEmpty {
                    deployments = try await read(link, commit: nil, limit: 1)
                    records = deployments.map(\.record)
                    result.isLatestFallback = true
                } else if sha == nil {
                    result.isLatestFallback = true
                }
            }
            if result.project == nil {
                result.project = deployments.first?.name.map(OfficePipeline.label)
            }
            result.records = Array(records.prefix(useLatestFallback && result.isLatestFallback ? 1 : 10))
        } catch {
            result.error = (error as? ReadError ?? .unavailable).rawValue
        }
        return result
    }

    private func read(_ link: OfficeVercelProjectLink, commit: String?, limit: Int) async throws -> [DeploymentList.Deployment] {
        try Task.checkCancellation()
        var query = URLComponents()
        query.path = "/v7/deployments"
        query.queryItems = [URLQueryItem(name: "projectId", value: link.projectId),
                            URLQueryItem(name: "limit", value: String(limit))]
        if link.orgId.hasPrefix("team_") { query.queryItems?.append(URLQueryItem(name: "teamId", value: link.orgId)) }
        if let commit { query.queryItems?.append(URLQueryItem(name: "sha", value: commit)) }
        guard let endpoint = query.string else { throw ReadError.unavailable }
        let data: Data
        if let fetch { data = try await fetch(endpoint) }
        else { data = try await Self.cliGET(endpoint) }
        try Task.checkCancellation()
        return try JSONDecoder().decode(DeploymentList.self, from: data).deployments
            .filter { $0.projectId == nil || $0.projectId == link.projectId }
    }

    private static func normalizedSHA(_ value: String) -> String? {
        value.range(of: #"\A[a-fA-F0-9]{7,64}\z"#, options: .regularExpression) == nil ? nil : value.lowercased()
    }

    private enum ReadError: String, Error {
        case cliMissing, cliTooOld, cliUnavailable, unavailable
    }

    private static func cliGET(_ endpoint: String) async throws -> Data {
        guard let vercel = OfficePipelineCommand.installed("vercel") else { throw ReadError.cliMissing }
        let task = Task.detached(priority: .utility) {
            guard let output = OfficePipelineCommand.read(vercel, ["--version"], includeStderr: true),
                  supportsAPI(String(decoding: output, as: UTF8.self)) else { throw ReadError.cliTooOld }
            guard let response = OfficePipelineCommand.read(vercel, ["api", endpoint, "--method", "GET", "--raw", "--non-interactive"])
            else { throw ReadError.cliUnavailable }
            return response
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func supportsAPI(_ output: String) -> Bool {
        let version = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.hasPrefix("Vercel CLI ") ? String(line.dropFirst("Vercel CLI ".count)) : String(line)
            guard value.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.\-]+)?\z"#,
                              options: .regularExpression) != nil else { return nil }
            return value
        }.first
        guard let version, !version.contains("-") else { return false }
        let parts = version.split(whereSeparator: { $0 == "-" || $0 == "+" }).first?.split(separator: ".") ?? []
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 && !numbers.lexicographicallyPrecedes([50, 5, 1])
    }

    private struct RepoLinks: Decodable {
        struct Project: Decodable {
            let id: String
            let name: String
            let directory: String
            let orgId: String?
        }

        let orgId: String?
        let remoteName: String?
        let projects: [Project]
    }

    private static func repositoryLinks(_ workspace: OfficePipelineWorkspace) -> [OfficeVercelProjectLink] {
        let directories = [workspace.directory, workspace.gitRoot].compactMap { $0 }
        var links = directories.compactMap { directory -> OfficeVercelProjectLink? in
            guard let link: OfficeVercelProjectLink = readLink("project.json", in: directory), link.valid else { return nil }
            return link
        }
        if let root = workspace.gitRoot, let repo: RepoLinks = readLink("repo.json", in: root),
           repo.remoteName == nil || repo.remoteName == "origin" {
            links += repo.projects.compactMap { project in projectLink(project, repo: repo, root: root)?.link }
        }
        return links
    }

    private static func projectLink(_ project: RepoLinks.Project, repo: RepoLinks, root: URL) -> (path: String, link: OfficeVercelProjectLink)? {
        guard !project.directory.hasPrefix("/"), !project.directory.contains("\0"),
              let orgId = project.orgId ?? repo.orgId else { return nil }
        let path = root.appendingPathComponent(project.directory, isDirectory: true).standardizedFileURL.path
        guard activityPath(path, liesIn: root.standardizedFileURL.path) else { return nil }
        let link = OfficeVercelProjectLink(projectId: project.id, orgId: orgId, projectName: project.name)
        return link.valid ? (path, link) : nil
    }

    private static func link(in workspace: OfficePipelineWorkspace) -> OfficeVercelProjectLink? {
        if let exact: OfficeVercelProjectLink = readLink("project.json", in: workspace.directory), exact.valid { return exact }
        guard let root = workspace.gitRoot else { return nil }
        if let repo: RepoLinks = readLink("repo.json", in: root) {
            let path = workspace.directory.standardizedFileURL.path
            let matches = repo.projects.compactMap { projectLink($0, repo: repo, root: root) }
                .filter { activityPath(path, liesIn: $0.path) }
            guard let depth = matches.map({ $0.path.count }).max() else { return nil }
            let candidates = matches.filter { $0.path.count == depth }
            return candidates.count == 1 ? candidates.first?.link : nil
        }
        guard let project: OfficeVercelProjectLink = readLink("project.json", in: root), project.valid else { return nil }
        return project
    }

    private static func readLink<T: Decodable>(_ filename: String, in directory: URL) -> T? {
        let file = directory.appendingPathComponent(".vercel", isDirectory: true).appendingPathComponent(filename)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, (1...131_072).contains(size),
              let data = try? Data(contentsOf: file), data.count <= 131_072 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private struct DeploymentList: Decodable {
        struct Deployment: Decodable {
            struct CustomEnvironment: Decodable { let slug: String? }
            struct AliasError: Decodable { let code: String? }
            struct GitSource: Decodable {
                let sha: String?
                let ref: String?
            }
            struct Meta: Decodable {
                let githubCommitRef: String?
                let githubCommitSha: String?
                let gitlabCommitRef: String?
                let gitlabCommitSha: String?
                let bitbucketCommitRef: String?
                let bitbucketCommitSha: String?
                let gitCommitRef: String?
                let gitCommitSha: String?
            }

            let projectId: String?
            let name: String?
            let state: String?
            let readyState: String?
            let readySubstate: String?
            let target: String?
            let customEnvironment: CustomEnvironment?
            let created: Double?
            let createdAt: Double?
            let ready: Double?
            let errorCode: String?
            let aliasError: AliasError?
            let inspectorUrl: String?
            let gitSource: GitSource?
            let meta: Meta?

            var record: OfficeDeploymentRecord {
                let state = (readyState ?? state ?? "unknown").lowercased()
                let environment = customEnvironment?.slug ?? target ?? "preview"
                let sha = [gitSource?.sha, meta?.githubCommitSha, meta?.gitlabCommitSha, meta?.bitbucketCommitSha, meta?.gitCommitSha]
                    .compactMap { $0 }.compactMap(OfficeVercelDeployments.normalizedSHA).first
                let ref = [gitSource?.ref, meta?.githubCommitRef, meta?.gitlabCommitRef, meta?.bitbucketCommitRef, meta?.gitCommitRef]
                    .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let finish = state == "ready" ? ready : nil
                let time = (finish ?? createdAt ?? created).flatMap { value -> String? in
                    guard (1...253_402_300_800_000).contains(value) else { return nil }
                    return officeISODate(Date(timeIntervalSince1970: value / 1000))
                }
                let url = inspectorUrl.flatMap(URLComponents.init(string:)).flatMap { value -> URL? in
                    guard value.scheme == "https", value.host?.lowercased() == "vercel.com", value.user == nil,
                          value.password == nil, value.port == nil else { return nil }
                    var link = value
                    link.query = nil
                    link.fragment = nil
                    return link.url
                }
                return OfficeDeploymentRecord(
                    environment: OfficePipeline.label(environment), state: state,
                    release: state == "ready" && target == "production" ? readySubstate?.lowercased() : nil,
                    branch: ref.map(OfficePipeline.label), commit: sha, observedAt: time,
                    errorCode: (errorCode ?? aliasError?.code).map(OfficePipeline.label), url: url
                )
            }
        }

        let deployments: [Deployment]
    }
}

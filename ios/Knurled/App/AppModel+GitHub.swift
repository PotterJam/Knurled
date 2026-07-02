import Foundation

/// The GitHub repository a training repo is backed up to. The working copy in iCloud/local
/// storage is the source of truth; this remote just mirrors it, one commit per change.
struct GitHubRemote: Codable, Sendable, Hashable {
    let owner: String
    let name: String
    let branch: String
    var headCommit: String
}

/// A built-in starter template, as described by the engine. The app never invents template
/// identifiers or names — `reference`, `title`, and `subtitle` all come from
/// `knurled_builtin_templates` so the two can't drift apart.
struct StarterTemplate: Codable, Sendable, Hashable, Identifiable {
    let reference: String
    let title: String
    let subtitle: String

    var id: String { reference }

    // The shared decoder uses `.convertFromSnakeCase`, so the engine's `display_name`
    // arrives as `displayName` before keys are matched — map against the converted form.
    private enum CodingKeys: String, CodingKey {
        case reference
        case title = "displayName"
        case subtitle = "description"
    }
}

/// The canonical + generated files a training commit may touch (spec §28).
enum GitHubChangedFiles {
    static func present(in dir: URL) -> [String] {
        var paths: [String] = []
        // Logs follow the engine convention logs/<yyyy>/<mm>.json; build the repo-relative
        // path from the trailing components to stay robust to /var -> /private symlinks.
        let logs = dir.appending(path: "logs", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                paths.append("logs/" + url.pathComponents.suffix(2).joined(separator: "/"))
            }
        }
        for generated in ["state/current.json", "build/current.ir.json",
                          "build/next-workout.json", "build/validation.json"] {
            if FileManager.default.fileExists(atPath: dir.appending(path: generated).path(percentEncoded: false)) {
                paths.append(generated)
            }
        }
        let programs = dir.appending(path: "programs", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(at: programs, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "current.json"
                && url.deletingLastPathComponent().lastPathComponent == "state" {
                if let relative = repoRelativePath(for: url, root: dir) { paths.append(relative) }
            }
        }
        return paths
    }

    static func all(in dir: URL) -> [String] {
        let base = dir.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            guard let relative = repoRelativePath(for: url, root: base) else { continue }
            paths.append(relative)
        }
        return paths.sorted()
    }

    static func repoRelativePath(for url: URL, root: URL) -> String? {
        // The root and enumerated URLs can disagree on the /private/var prefix on iOS. Normalize
        // that alias before comparing components; otherwise dropping the root component count
        // leaves the repo directory name in the returned path.
        let baseComponents = normalizedPathComponents(root)
        let fileComponents = normalizedPathComponents(url)
        guard fileComponents.count > baseComponents.count,
              Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }

        let relative = fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".DS_Store") else {
            return nil
        }
        return relative
    }

    private static func normalizedPathComponents(_ url: URL) -> [String] {
        var components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "private", components[2] == "var" {
            components.remove(at: 1)
        }
        return components
    }
}

extension AppModel {
    /// Backs the active training repo up to a brand-new GitHub repository: creates the repo,
    /// pushes every working-copy file as the initial commit, and records it as the backup
    /// remote. From then on every training commit also lands on GitHub.
    func createBackupRepository(name rawName: String, isPrivate: Bool = true) async throws {
        guard let repo = activeRepo else {
            throw GitHubError.badResponse("There is no training repo to back up yet.")
        }
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRepositoryName(name) else { throw GitHubError.invalidRepositoryName }

        let githubRepo = try await client.createRepository(name: name, isPrivate: isPrivate)
        try await backUp(repo, to: githubRepo, client: client)
        await github.loadRepos()
    }

    /// Backs the active training repo up into an existing, empty GitHub repository (the
    /// offer made when a restore attempt hits GitHub's empty-repo 409).
    func backUpToExistingRepository(_ githubRepo: GitHubRepo) async throws {
        guard let repo = activeRepo else {
            throw GitHubError.badResponse("There is no training repo to back up yet.")
        }
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        try await backUp(repo, to: githubRepo, client: client)
    }

    private func backUp(
        _ repo: ActiveRepo,
        to githubRepo: GitHubRepo,
        client: any GitHubClientProtocol
    ) async throws {
        let branch = githubRepo.defaultBranch.isEmpty ? "main" : githubRepo.defaultBranch
        let head = try await client.commitInitial(
            owner: githubRepo.owner,
            repo: githubRepo.name,
            branch: branch,
            files: GitHubChangedFiles.all(in: repo.url),
            dir: repo.url,
            message: "Back up Knurled training repo"
        )
        repo.remote = GitHubRemote(
            owner: githubRepo.owner,
            name: githubRepo.name,
            branch: branch,
            headCommit: head
        )
        repo.pendingPush = false
        persistSelection()
    }

    /// Stops backing the active repo up to GitHub. The working copy and its history stay
    /// intact locally and on GitHub; Knurled just stops pushing new commits.
    func unlinkBackup() {
        activeRepo?.remote = nil
        activeRepo?.pendingPush = false
        persistSelection()
    }

    /// Restores a training repo from its GitHub backup: pulls the repository into a fresh
    /// working copy in primary storage and makes it the active repo.
    ///
    /// Empty repositories (no commits yet) can't be restored from — GitHub's Git Data API
    /// answers with 409. We surface `GitHubError.emptyRepository` so the caller can offer to
    /// back up into it instead via `backUpToExistingRepository`.
    func restoreFromBackup(repo githubRepo: GitHubRepo) async throws {
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        let slug = "\(githubRepo.owner)-\(githubRepo.name)"
        let dir = try await repos.workingDirectory(for: slug)
        let head: String
        do {
            head = try await client.pull(
                owner: githubRepo.owner,
                repo: githubRepo.name,
                branch: githubRepo.defaultBranch,
                into: dir
            )
        } catch where GitHubError.isEmptyRepository(error) {
            throw GitHubError.emptyRepository
        }
        let active = ActiveRepo(displayName: githubRepo.fullName, url: dir)
        active.remote = GitHubRemote(
            owner: githubRepo.owner,
            name: githubRepo.name,
            branch: githubRepo.defaultBranch,
            headCommit: head
        )
        _ = try await engine.build(dir: dir, write: false)
        await active.refresh(engine: engine)
        activeRepo = active
        phase = .ready
        persistSelection()
    }

    private static func isValidRepositoryName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Pulls the latest backup state into the active repo and rebuilds (spec §27).
    func sync() async {
        guard let repo = activeRepo, let remote = repo.remote, let client = github.client() else {
            await refresh()
            return
        }
        if repo.pendingPush {
            do {
                try await push(repo: repo, message: "Sync pending Knurled changes")
            } catch {
                do {
                    try await reconcilePendingLogsWithRemote(repo: repo, remote: remote, client: client)
                } catch {
                    repo.pendingPush = true
                    repo.loadError = "Saved locally. Couldn't sync with GitHub yet: \(error.localizedDescription)"
                    persistSelection()
                    return
                }
            }
            persistSelection()
        }
        do {
            let head = try await client.pull(
                owner: remote.owner,
                repo: remote.name,
                branch: remote.branch,
                into: repo.url
            )
            repo.remote?.headCommit = head
            _ = try await engine.build(dir: repo.url, write: true)
            await repo.refresh(engine: engine)
            persistSelection()
        } catch {
            repo.loadError = error.localizedDescription
        }
    }

    /// Pushes the working copy's changed files as one commit. Best-effort: a failure
    /// (e.g. offline) marks the repo pending rather than losing the local commit (spec §30).
    func pushIfConnected(repo: ActiveRepo, message: String, files: [String]? = nil) async {
        do {
            try await push(repo: repo, message: message, files: files)
        } catch {
            repo.pendingPush = true
            repo.loadError = "Saved locally. Couldn't push to GitHub yet: \(error.localizedDescription)"
        }
    }

    func push(repo: ActiveRepo, message: String, files explicitFiles: [String]? = nil) async throws {
        guard let remote = repo.remote, let client = github.client() else { return }
        let head = try await client.commit(
            owner: remote.owner,
            repo: remote.name,
            branch: remote.branch,
            baseCommit: remote.headCommit,
            files: explicitFiles ?? GitHubChangedFiles.present(in: repo.url),
            dir: repo.url,
            message: message
        )
        repo.remote?.headCommit = head
        repo.pendingPush = false
    }

    private func reconcilePendingLogsWithRemote(
        repo: ActiveRepo,
        remote: GitHubRemote,
        client: any GitHubClientProtocol
    ) async throws {
        let remoteDir = FileManager.default.temporaryDirectory
            .appending(path: "KnurledSync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: remoteDir) }

        let latestHead = try await client.pull(
            owner: remote.owner,
            repo: remote.name,
            branch: remote.branch,
            into: remoteDir
        )
        _ = try await engine.mergeRecordRepos(source: repo.url, target: remoteDir)

        try? FileManager.default.removeItem(at: repo.url)
        try FileManager.default.copyItem(at: remoteDir, to: repo.url)
        repo.remote?.headCommit = latestHead
        _ = try await engine.build(dir: repo.url, write: true)
        try await push(repo: repo, message: "Sync pending Knurled changes")
    }

}

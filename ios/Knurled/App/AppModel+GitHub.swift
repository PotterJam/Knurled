import Foundation

struct GitHubRemote: Codable, Sendable, Hashable {
    let owner: String
    let name: String
    let branch: String
    var headCommit: String
}

/// The canonical + generated files a training commit may touch (spec §28).
enum GitHubChangedFiles {
    static func present(in dir: URL) -> [String] {
        var paths: [String] = []
        // Logs follow the engine convention logs/<yyyy>/<mm>.jsonl; build the repo-relative
        // path from the trailing components to stay robust to /var -> /private symlinks.
        let logs = dir.appending(path: "logs", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                paths.append("logs/" + url.pathComponents.suffix(2).joined(separator: "/"))
            }
        }
        for generated in ["state/current.json", "build/state.json", "build/ir.json",
                          "build/next-workout.json", "build/validation.json"] {
            if FileManager.default.fileExists(atPath: dir.appending(path: generated).path(percentEncoded: false)) {
                paths.append(generated)
            }
        }
        return paths
    }
}

extension AppModel {
    /// Pulls a GitHub repo into a working copy and makes it the active repo.
    func connect(repo githubRepo: GitHubRepo) async throws {
        guard let client = github.client() else { throw GitHubError.badResponse }
        let slug = "\(githubRepo.owner)-\(githubRepo.name)"
        let dir = try repos.workingDirectory(for: slug)
        let head = try await client.pull(
            owner: githubRepo.owner,
            repo: githubRepo.name,
            branch: githubRepo.defaultBranch,
            into: dir
        )
        let active = ActiveRepo(displayName: githubRepo.fullName, url: dir, isSample: false)
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

    /// Pulls the latest remote state into the active GitHub repo and rebuilds (spec §27).
    func sync() async {
        guard let repo = activeRepo, let remote = repo.remote, let client = github.client() else {
            await refresh()
            return
        }
        if repo.pendingPush {
            repo.loadError = "You have local changes that haven't pushed yet. Push before pulling."
            return
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
        } catch {
            repo.loadError = error.localizedDescription
        }
    }

    /// Pushes the working copy's changed files as one commit. Best-effort: a failure
    /// (e.g. offline) marks the repo pending rather than losing the local commit (spec §30).
    func pushIfConnected(repo: ActiveRepo, message: String) async {
        guard let remote = repo.remote, let client = github.client() else { return }
        do {
            let head = try await client.commit(
                owner: remote.owner,
                repo: remote.name,
                branch: remote.branch,
                baseCommit: remote.headCommit,
                files: GitHubChangedFiles.present(in: repo.url),
                dir: repo.url,
                message: message
            )
            repo.remote?.headCommit = head
            repo.pendingPush = false
        } catch {
            repo.pendingPush = true
            repo.loadError = "Saved locally. Couldn't push to GitHub yet: \(error.localizedDescription)"
        }
    }
}

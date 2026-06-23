import Foundation

/// A persisted pointer to the last-active repo so "connect repo → reopen app → next workout"
/// survives relaunch, and so unpushed local commits aren't stranded behind a sample-repo boot.
struct RepoSelection: Codable, Sendable {
    var slug: String
    var displayName: String
    var isSample: Bool
    var remote: GitHubRemote?
    var pendingPush: Bool
}

extension AppModel {
    private static let selectionKey = "knurled.activeRepoSelection"

    func persistSelection() {
        guard let repo = activeRepo else { return }
        let selection = RepoSelection(
            slug: repo.url.lastPathComponent,
            displayName: repo.displayName,
            isSample: repo.isSample,
            remote: repo.remote,
            pendingPush: repo.pendingPush
        )
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }

    /// Re-opens the last connected GitHub repo from its on-disk working copy. Returns false
    /// (so the caller falls back to the sample) when there is no connected selection or its
    /// working copy is missing.
    func restoreSelection() async -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.selectionKey),
              let selection = try? JSONDecoder().decode(RepoSelection.self, from: data),
              !selection.isSample,
              let dir = try? repos.workingDirectory(for: selection.slug),
              FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        else { return false }

        let repo = ActiveRepo(displayName: selection.displayName, url: dir, isSample: false)
        repo.remote = selection.remote
        repo.pendingPush = selection.pendingPush
        await repo.refresh(engine: engine)
        activeRepo = repo
        phase = .ready
        return true
    }
}

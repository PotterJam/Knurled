import Foundation

/// A persisted pointer to the last-active repo so "set up → reopen app → next workout"
/// survives relaunch, and so unpushed backup commits aren't stranded by a fresh boot.
struct RepoSelection: Codable, Sendable {
    var slug: String
    var displayName: String
    /// Legacy field: builds before onboarding persisted the bundled sample repo with this
    /// flag. Kept optional so old selections still decode — and get skipped on restore.
    var isSample: Bool?
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
            remote: repo.remote,
            pendingPush: repo.pendingPush
        )
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }

    /// Re-opens the last-active repo from its on-disk working copy — iCloud first, then local
    /// storage. Returns false (so the caller routes into onboarding) when nothing was
    /// persisted, the working copy is gone, or the selection is a legacy sample repo.
    func restoreSelection() async -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.selectionKey),
              let selection = try? JSONDecoder().decode(RepoSelection.self, from: data),
              selection.isSample != true,
              let dir = await repos.existingWorkingDirectory(for: selection.slug)
        else { return false }

        let repo = ActiveRepo(displayName: selection.displayName, url: dir)
        repo.remote = selection.remote
        repo.pendingPush = selection.pendingPush
        await repo.refresh(engine: engine)
        activeRepo = repo
        phase = .ready
        return true
    }
}

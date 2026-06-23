import Foundation

extension AppModel {
    /// The single path every training action funnels through (complete, partial, skip,
    /// correction, continue). Owning the sequence in one place keeps append → rebuild →
    /// refresh → push semantics — and the pending-push/persist bookkeeping — identical
    /// across actions.
    func record(
        eventLine: String,
        in repo: ActiveRepo,
        timestamp: String,
        message: String
    ) async throws {
        try LogReader().appendEvent(line: eventLine, dir: repo.url, timestamp: timestamp)
        _ = try await engine.build(dir: repo.url, write: true)
        await repo.refresh(engine: engine)
        await pushIfConnected(repo: repo, message: message)
        persistSelection()
    }
}

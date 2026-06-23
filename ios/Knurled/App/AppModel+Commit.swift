import Foundation

extension AppModel {
    enum CommitError: Error, LocalizedError {
        case noEvent

        var errorDescription: String? {
            "The engine did not produce an event to commit."
        }
    }

    @discardableResult
    func commit(
        outcome: ReductionOutcome,
        in repo: ActiveRepo,
        timestamp: String
    ) async throws -> ReductionResult {
        guard outcome.result.validation.isValid, let line = outcome.eventLine else {
            throw CommitError.noEvent
        }
        try LogReader().appendEvent(line: line, dir: repo.url, timestamp: timestamp)
        _ = try await engine.build(dir: repo.url, write: true)
        await repo.refresh(engine: engine)
        await pushIfConnected(repo: repo, message: Self.commitMessage(for: outcome.result.event, timestamp: timestamp))
        return outcome.result
    }

    /// Per-action commit message templates (spec §28).
    static func commitMessage(for event: TrainingEvent?, timestamp: String) -> String {
        let session = (event?.sessionId ?? "session").uppercased()
        let date = String(timestamp.prefix(10))
        switch event?.type {
        case "session_completed": return "Complete \(session) - \(date)"
        case "session_saved": return "Save partial \(session) - \(date)"
        case "session_skipped": return "Skip \(session) - push forward - \(date)"
        case "session_corrected": return "Correct \(session) - \(date)"
        default: return "Update training log - \(date)"
        }
    }
}

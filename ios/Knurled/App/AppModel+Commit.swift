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
        return outcome.result
    }
}

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
        timestamp: String,
        continuesEventId: String? = nil
    ) async throws -> ReductionResult {
        guard outcome.result.validation.isValid, let baseLine = outcome.eventLine else {
            throw CommitError.noEvent
        }
        let line: String
        let message: String
        if let continuesEventId {
            line = try Self.rewriteAsContinued(baseLine, continuesEventId: continuesEventId, timestamp: timestamp)
            let session = (outcome.result.event?.sessionId ?? "session").uppercased()
            let date = String(timestamp.prefix(10))
            message = outcome.result.event?.type == "session_completed"
                ? "Continue \(session) - \(date)"
                : "Save partial \(session) - \(date)"
        } else {
            line = baseLine
            message = Self.commitMessage(for: outcome.result.event, timestamp: timestamp)
        }
        try await record(eventLine: line, in: repo, timestamp: timestamp, message: message)
        return outcome.result
    }

    /// Links a finished resumed workout back to the partial it continues, so the original is
    /// superseded rather than duplicated (§19).
    ///
    /// A *complete* finish is relabelled `session_completed` → `session_continued` so replay
    /// guards the cursor advance the partial already made. A still-*partial* finish stays
    /// `session_saved` (its replay already guards the cursor) and only carries the link — that
    /// drops the superseded partial out of the resumable set and out of History.
    private static func rewriteAsContinued(
        _ line: String,
        continuesEventId: String,
        timestamp: String
    ) throws -> String {
        var event = try KnurledCoding.decoder().decode(TrainingEvent.self, from: Data(line.utf8))
        if event.type == "session_completed" {
            event.type = "session_continued"
        }
        event.continuesEventId = continuesEventId
        if let session = event.sessionId {
            event.id = EventID.make(type: event.type, session: session, timestamp: timestamp)
        }
        return try EventEncoding.line(event)
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

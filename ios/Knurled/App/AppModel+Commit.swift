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
            message = "Continue \(session) - \(String(timestamp.prefix(10)))"
        } else {
            line = baseLine
            message = Self.commitMessage(for: outcome.result.event, timestamp: timestamp)
        }
        try await record(eventLine: line, in: repo, timestamp: timestamp, message: message)
        return outcome.result
    }

    /// Relabels the engine's `session_completed` as a `session_continued` linked to the saved
    /// partial it finishes. The engine replays both the same way (apply effects, advance cursor)
    /// but History can then show them as one workout (§19).
    private static func rewriteAsContinued(
        _ line: String,
        continuesEventId: String,
        timestamp: String
    ) throws -> String {
        var event = try KnurledCoding.decoder().decode(TrainingEvent.self, from: Data(line.utf8))
        event.type = "session_continued"
        event.continuesEventId = continuesEventId
        if let session = event.sessionId {
            event.id = EventID.make(type: "session_continued", session: session, timestamp: timestamp)
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

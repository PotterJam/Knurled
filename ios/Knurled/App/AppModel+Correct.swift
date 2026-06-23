import Foundation

extension AppModel {
    /// Records a `session_corrected` event that edits actual reps on a prior event.
    /// The engine re-folds the correction (recomputing outcomes/effects) on the next build —
    /// the original event is never rewritten in place (§20).
    func correct(
        event original: TrainingEvent,
        changes: [CorrectionChange],
        in repo: ActiveRepo,
        timestamp: String = LiveWorkout.timestamp()
    ) async throws {
        guard !changes.isEmpty else { return }
        let event = TrainingEvent(
            id: EventID.make(
                type: "session_corrected",
                session: original.sessionId ?? "session",
                timestamp: timestamp
            ),
            type: "session_corrected",
            schemaVersion: "0.1",
            program: original.program,
            sessionId: original.sessionId,
            planHash: original.planHash,
            templateHash: original.templateHash,
            renderedSessionHash: original.renderedSessionHash,
            engineVersion: original.engineVersion,
            startedAt: nil,
            completedAt: timestamp,
            savedAt: nil,
            status: nil,
            results: [],
            resultsAdded: [],
            effects: [],
            continuesEventId: nil,
            correctsEventId: original.id,
            reason: nil,
            policy: nil,
            lane: nil,
            change: nil,
            cursor: nil,
            changes: changes
        )
        let line = try EventEncoding.line(event)
        try await record(
            eventLine: line,
            in: repo,
            timestamp: timestamp,
            message: Self.commitMessage(for: event, timestamp: timestamp)
        )
    }
}

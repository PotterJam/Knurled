import Foundation

enum SkipPolicy {
    static let pushForward = "push_forward"
    static let repeatNextTime = "repeat_next_time"
}

enum EventID {
    /// Mirrors the engine id convention, e.g. `evt_20260622t203122z_session_skipped_b1`.
    static func make(type: String, session: String, timestamp: String) -> String {
        let compact = timestamp.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        return "evt_\(compact)_\(type)_\(session)"
    }
}

enum EventEncoding {
    /// Serializes a hand-built event to the same single-line snake_case JSON the engine emits.
    static func line(_ event: TrainingEvent) throws -> String {
        let data = try KnurledCoding.encoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }
}

extension AppModel {
    func skip(
        session: RenderedSession,
        in repo: ActiveRepo,
        reason: String?,
        policy: String = SkipPolicy.pushForward,
        timestamp: String = LiveWorkout.timestamp()
    ) async throws {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = TrainingEvent(
            id: EventID.make(type: "session_skipped", session: session.sessionId, timestamp: timestamp),
            type: "session_skipped",
            schemaVersion: "0.1",
            program: repo.events.compactMap(\.program).first,
            sessionId: session.sessionId,
            planHash: session.planHash,
            templateHash: session.templateHash,
            renderedSessionHash: session.renderedSessionHash,
            engineVersion: session.engineVersion,
            startedAt: nil,
            completedAt: timestamp,
            savedAt: nil,
            status: nil,
            results: [],
            resultsAdded: [],
            effects: [],
            continuesEventId: nil,
            correctsEventId: nil,
            reason: (trimmed?.isEmpty == false) ? trimmed : nil,
            policy: policy,
            lane: nil,
            change: nil,
            cursor: nil,
            changes: []
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

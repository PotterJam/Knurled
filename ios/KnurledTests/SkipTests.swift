import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct SkipTests {
    // §24 — Skipping records a session_skipped event and pushes the cursor forward,
    // through the real engine fold (append event -> build_repo -> advance_cursor).
    @Test func skipAdvancesCursorAndRecordsEvent() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()

        let before = try await engine.build(dir: dir, write: false)
        let session = try #require(before.nextWorkout)
        #expect(session.sessionId == "a1")

        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        await repo.refresh(engine: engine)
        let app = AppModel(engine: engine)

        try await app.skip(
            session: session,
            in: repo,
            reason: "travel",
            timestamp: "2026-06-24T09:00:00Z"
        )

        let after = try await engine.build(dir: dir, write: false)
        #expect(after.nextWorkout?.sessionId == "b1")
        #expect(after.state.cursor.nextSession == "b1")

        let events = LogReader().events(dir: dir)
        let skip = try #require(events.first { $0.type == "session_skipped" })
        #expect(skip.sessionId == "a1")
        #expect(skip.policy == SkipPolicy.pushForward)
        #expect(skip.reason == "travel")
        #expect(skip.id == "evt_20260624t090000z_session_skipped_a1")
    }
}

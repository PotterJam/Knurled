import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct CorrectionTests {
    // §20 — A correction edits a prior event's reps; the engine re-folds outcomes and
    // effects without rewriting the original log line.
    @Test func correctingRepsRefoldsState() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let app = AppModel(engine: engine)

        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            inputs: session.items.map { item in
                if item.executionContract.recommendedInput == InputMode.amrapFinalSet {
                    return ItemInput(
                        itemId: item.itemId,
                        mode: InputMode.amrapFinalSet,
                        finalSetReps: item.prescription.sets.last?.targetReps ?? 1
                    )
                }
                return ItemInput(
                    itemId: item.itemId,
                    mode: InputMode.perSetReps,
                    sets: item.prescription.sets.map { ActualSet(set: $0.set, load: $0.load, reps: $0.targetReps) }
                )
            }
        )
        let outcome = try await engine.reduce(dir: dir, session: session, input: input)
        try await app.commit(outcome: outcome, in: repo, timestamp: "2026-06-24T11:00:00Z")
        #expect(repo.state?.lanes["bench.t2"]?.load == "47.5kg")

        let completed = try #require(repo.events.first { $0.type == "session_completed" })
        let change = CorrectionChange(
            path: "results[a1.t2].actual[2].reps",
            before: .int(10),
            after: .int(8)
        )
        try await app.correct(event: completed, changes: [change], in: repo, timestamp: "2026-06-24T12:00:00Z")

        // Bench now reads as a miss: stage advances, the load increase is undone.
        #expect(repo.state?.lanes["bench.t2"]?.stage == "3x8")
        #expect(repo.state?.lanes["bench.t2"]?.load == "45kg")

        // Original completed event is untouched; the correction is a separate event.
        let events = LogReader().events(dir: dir)
        #expect(events.contains { $0.type == "session_corrected" && $0.correctsEventId == completed.id })
        let original = try #require(events.first { $0.id == completed.id })
        #expect(original.results.first { $0.slotId == "a1.t2" }?.actual.last?.reps == 10)
    }
}

import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct ContinueTests {
    @Test func incompleteWorkoutFinishInputIsResumablePartial() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        let workout = LiveWorkout(repo: repo, session: session)

        let bench = try #require(workout.items.first { $0.id == "a1.t2" })
        bench.sets[0].logged = true

        let input = workout.finishInput(timestamp: "2026-06-24T10:20:00Z")

        #expect(workout.canFinish)
        #expect(!workout.allRequiredComplete)
        #expect(workout.finishStatus == ExecutionStatus.partial)
        #expect(input.status == ExecutionStatus.partial)
        #expect(input.completedAt == nil)
        #expect(input.savedAt == "2026-06-24T10:20:00Z")
        #expect(input.inputs.map(\.itemId) == ["a1.t2"])
        #expect(input.inputs.first?.sets.map(\.set) == [1])
    }

    @Test func completeWorkoutFinishInputStillCompletes() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        let workout = LiveWorkout(repo: repo, session: session)

        for item in workout.requiredItems {
            for set in item.sets {
                set.logged = true
            }
        }

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")

        #expect(workout.canFinish)
        #expect(workout.allRequiredComplete)
        #expect(workout.finishStatus == ExecutionStatus.complete)
        #expect(input.status == ExecutionStatus.complete)
        #expect(input.completedAt == "2026-06-24T11:00:00Z")
        #expect(input.savedAt == nil)
        #expect(input.inputs.count == session.items.count)
    }

    // §16/§19/§31 — a partial save keeps in-progress sets without advancing the cursor, and
    // continuing finishes the same snapshot as a linked session_continued.
    @Test func partialSavePreservesSetsThenContinueCompletes() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let app = AppModel(engine: engine)

        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)

        // Partial: only 2 of the 3 bench sets (a1.t2) are logged.
        let partialInput = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.partial,
            startedAt: "2026-06-24T10:00:00Z",
            savedAt: "2026-06-24T10:20:00Z",
            inputs: [ItemInput(itemId: "a1.t2", mode: InputMode.perSetReps, sets: [
                ActualSet(set: 1, load: "45kg", reps: 10),
                ActualSet(set: 2, load: "45kg", reps: 10),
            ])]
        )
        let partial = try await engine.reduce(dir: dir, session: session, input: partialInput)
        try await app.commit(outcome: partial, in: repo, timestamp: "2026-06-24T10:20:00Z")

        let saved = try #require(repo.events.first { $0.type == "session_saved" })
        #expect(saved.results.first { $0.slotId == "a1.t2" }?.actual.count == 2)
        #expect(repo.state?.cursor.nextSession == "a1")

        // Continue: the snapshot still matches; finish the whole session linked to the partial.
        let again = try #require(repo.nextWorkout)
        #expect(again.renderedSessionHash == session.renderedSessionHash)
        let fullInput = ExecutionInput(
            renderedSessionHash: again.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: saved.startedAt,
            completedAt: "2026-06-24T11:00:00Z",
            inputs: again.items.map { item in
                if item.executionContract.recommendedInput == InputMode.amrapFinalSet {
                    return ItemInput(itemId: item.itemId, mode: InputMode.amrapFinalSet, finalSetReps: item.prescription.sets.last?.targetReps ?? 1)
                }
                return ItemInput(itemId: item.itemId, mode: InputMode.perSetReps, sets: item.prescription.sets.map { ActualSet(set: $0.set, load: $0.load, reps: $0.targetReps) })
            }
        )
        let full = try await engine.reduce(dir: dir, session: again, input: fullInput)
        try await app.commit(outcome: full, in: repo, timestamp: "2026-06-24T11:00:00Z", continuesEventId: saved.id)

        let events = LogReader().events(dir: dir)
        let continued = try #require(events.first { $0.type == "session_continued" })
        #expect(continued.continuesEventId == saved.id)
        #expect(repo.state?.cursor.nextSession == "b1")
    }
}

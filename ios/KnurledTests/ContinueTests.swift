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

    // §16/§19/§31 — a partial save keeps in-progress sets and advances the cursor to the next
    // workout, while the snapshot stays resumable from history and continuing finishes it as a
    // linked session_continued.
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
        // The partial moves the program on to B1, but A1 stays resumable from history.
        #expect(repo.state?.cursor.nextSession == "b1")
        #expect(repo.nextWorkout?.sessionId == "b1")

        // Continue from history: the saved snapshot is re-rendered and still matches.
        let again = try #require(
            repo.resumableSessions.first { $0.renderedSessionHash == saved.renderedSessionHash }
        )
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
        try await app.commit(outcome: full, in: repo, timestamp: "2026-06-24T11:00:00Z", continuesFrom: saved)

        let events = LogReader().events(dir: dir)
        let continued = try #require(events.first { $0.type == "session_continued" })
        #expect(continued.continuesEventId == saved.id)
        #expect(continued.results.isEmpty)
        #expect(continued.resultsAdded.count == 3)
        #expect(repo.state?.cursor.nextSession == "b1")

        // The partial and its continuation are one workout: History shows a single complete A1
        // row, not the partial duplicated alongside it (§19).
        let a1Rows = HistoryBuilder.items(from: repo.events).filter { $0.title == "A1" }
        #expect(a1Rows.count == 1)
        #expect(a1Rows.first?.status == "Complete")
    }

    // §19 — continuing a partial and saving it as a partial *again* must supersede the original
    // rather than leaving two resumable partials (the duplicate-on-resave bug). The re-save links
    // back to the original, which drops out of both the resumable set and History.
    @Test func continuingThenResavingPartialSupersedesTheOriginal() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let app = AppModel(engine: engine)

        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)

        let firstInput = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.partial,
            startedAt: "2026-06-24T10:00:00Z",
            savedAt: "2026-06-24T10:20:00Z",
            inputs: [ItemInput(itemId: "a1.t2", mode: InputMode.perSetReps, sets: [
                ActualSet(set: 1, load: "45kg", reps: 10),
            ])]
        )
        let first = try await engine.reduce(dir: dir, session: session, input: firstInput)
        try await app.commit(outcome: first, in: repo, timestamp: "2026-06-24T10:20:00Z")
        let original = try #require(repo.events.last { $0.type == "session_saved" })

        // Continue from history and save again, still partial (one more set logged).
        let resumed = try #require(
            repo.resumableSessions.first { $0.renderedSessionHash == original.renderedSessionHash }
        )
        let secondInput = ExecutionInput(
            renderedSessionHash: resumed.renderedSessionHash,
            status: ExecutionStatus.partial,
            startedAt: original.startedAt,
            savedAt: "2026-06-24T10:40:00Z",
            inputs: [ItemInput(itemId: "a1.t2", mode: InputMode.perSetReps, sets: [
                ActualSet(set: 1, load: "45kg", reps: 10),
                ActualSet(set: 2, load: "45kg", reps: 10),
            ])]
        )
        let second = try await engine.reduce(dir: dir, session: resumed, input: secondInput)
        try await app.commit(
            outcome: second, in: repo, timestamp: "2026-06-24T10:40:00Z", continuesFrom: original
        )

        // Both saves are on the log, but the re-save stays a partial that links to the original.
        let saves = repo.events.filter { $0.type == "session_saved" }
        #expect(saves.count == 2)
        let latest = try #require(saves.last)
        #expect(latest.continuesEventId == original.id)

        // Only the latest partial stays resumable — the original no longer duplicates it.
        #expect(repo.resumableSessions.filter { $0.sessionId == "a1" }.count == 1)
        // The re-save must not advance the cursor a second time.
        #expect(repo.state?.cursor.nextSession == "b1")

        // History shows one A1 row that can still be continued, not two.
        let a1Rows = HistoryBuilder.items(from: repo.events).filter { $0.title == "A1" }
        #expect(a1Rows.count == 1)
        #expect(a1Rows.first?.canContinue == true)
    }
}

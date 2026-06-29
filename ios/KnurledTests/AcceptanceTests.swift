import Testing
import Foundation
@testable import Knurled

@Suite struct AcceptanceTests {
    private func makeSample() throws -> URL { try SampleRepo.makeWorkingCopy() }

    private func rendered(_ engine: RustWorkoutEngine, _ dir: URL) async throws -> RenderedSession {
        try #require(try await engine.build(dir: dir, write: false).nextWorkout)
    }

    private func passingInputs(
        _ session: RenderedSession,
        override: [String: ItemInput] = [:]
    ) -> [ItemInput] {
        session.items.map { item in
            if let custom = override[item.itemId] { return custom }
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
    }

    private func reduce(
        _ engine: RustWorkoutEngine,
        _ dir: URL,
        _ session: RenderedSession,
        override: [String: ItemInput]
    ) async throws -> ReductionResult {
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            startedAt: "2026-06-24T10:10:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            inputs: passingInputs(session, override: override)
        )
        return try await engine.reduce(dir: dir, session: session, input: input)
    }

    private func result(_ outcome: ReductionResult, slot: String) -> ExerciseResult? {
        outcome.results.first { $0.slotId == slot }
    }

    // §40.2 — AMRAP input saves numeric reps with no Done/Missed ambiguity.
    @Test func amrapInputSavesNumericReps() async throws {
        let dir = try makeSample(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let session = try await rendered(engine, dir)

        let outcome = try await reduce(engine, dir, session, override: [
            "a1.t1": ItemInput(itemId: "a1.t1", mode: InputMode.amrapFinalSet, finalSetReps: 7)
        ])

        let squat = try #require(result(outcome, slot: "a1.t1"))
        #expect(squat.outcome == "pass")
        #expect(squat.actual.last?.reps == 7)
        #expect(squat.effects.contains { $0.op == "increase_load" && $0.to == "85kg" })
    }

    // §40.3 — Straight-set miss yields fail and the template failure effect.
    @Test func straightSetMissAdvancesStage() async throws {
        let dir = try makeSample(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let session = try await rendered(engine, dir)

        let missedBench = ItemInput(
            itemId: "a1.t2",
            mode: InputMode.perSetReps,
            sets: [
                ActualSet(set: 1, load: "45kg", reps: 10),
                ActualSet(set: 2, load: "45kg", reps: 10),
                ActualSet(set: 3, load: "45kg", reps: 8),
            ]
        )
        let outcome = try await reduce(engine, dir, session, override: ["a1.t2": missedBench])

        let bench = try #require(result(outcome, slot: "a1.t2"))
        #expect(bench.outcome == "fail")
        #expect(bench.actual.map(\.reps) == [10, 10, 8])
        #expect(bench.effects.contains { $0.op == "advance_stage" && $0.to == "3x8" })
    }

    // §40.4 — Adjust today logs adjusted_today and does not change the future plan.
    @Test func adjustTodayDoesNotProgress() async throws {
        let dir = try makeSample(); defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let session = try await rendered(engine, dir)

        let adjusted = ItemInput(
            itemId: "a1.t1",
            mode: InputMode.amrapFinalSet,
            finalSetReps: 6,
            load: "77.5kg"
        )
        let outcome = try await reduce(engine, dir, session, override: ["a1.t1": adjusted])

        let squat = try #require(result(outcome, slot: "a1.t1"))
        #expect(squat.outcome == "adjusted_today")
        #expect(squat.effects.isEmpty)
        #expect(outcome.newState.lanes["squat.t1"]?.load == "80kg")
    }
}

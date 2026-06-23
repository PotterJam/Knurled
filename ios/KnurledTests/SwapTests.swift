import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct SwapTests {
    // §5.4A — An approved swap records performed vs prescribed exercise and the policy,
    // and is tracking-only by default (prescribed progression lane is unchanged).
    @Test func swapRecordsPerformedExercise() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)

        let t3 = try #require(session.items.first { $0.itemId == "a1.t3" })
        let options = try #require(t3.exerciseOptions)
        #expect(options.alternatives.contains { $0.exercise == "chin_up" })

        var inputs = session.items.map { item -> ItemInput in
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
        if let index = inputs.firstIndex(where: { $0.itemId == "a1.t3" }) {
            inputs[index] = ItemInput(
                itemId: "a1.t3",
                mode: InputMode.amrapFinalSet,
                finalSetReps: 15,
                performedExercise: "chin_up",
                swapReason: "preferred alternative",
                swapPolicy: .trackingOnly
            )
        }
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T11:00:00Z",
            inputs: inputs
        )
        let outcome = try await engine.reduce(dir: dir, session: session, input: input)

        let result = try #require(outcome.result.event?.results.first { $0.slotId == "a1.t3" })
        #expect(result.performedExercise == "chin_up")
        #expect(result.prescribedExercise == "lat_pulldown")
        #expect(result.swapPolicy == .trackingOnly)
    }
}

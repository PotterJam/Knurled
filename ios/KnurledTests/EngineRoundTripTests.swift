import Testing
import Foundation
@testable import Knurled

@Suite struct EngineRoundTripTests {
    @Test func validatesAndBuildsSampleRepo() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RustWorkoutEngine()
        let version = try await engine.engineVersion()
        #expect(!version.isEmpty)

        let validation = try await engine.validate(dir: dir)
        #expect(validation.isValid)

        let outputs = try await engine.build(dir: dir, write: false)
        let next = try #require(outputs.nextWorkout)
        #expect(next.sessionId == "a1")
        #expect(next.items.count == 3)
    }

    @Test func reducingCompletedSessionAdvancesCursorAndProgressesLane() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RustWorkoutEngine()
        let rendered = try #require(try await engine.build(dir: dir, write: false).nextWorkout)

        let input = ExecutionInput(
            renderedSessionHash: rendered.renderedSessionHash,
            status: ExecutionStatus.complete,
            startedAt: "2026-06-24T10:10:00+01:00",
            completedAt: "2026-06-24T11:00:00+01:00",
            inputs: rendered.items.map(Self.passingInput)
        )

        let outcome = try await engine.reduce(dir: dir, input: input)
        #expect(outcome.result.validation.isValid)

        let event = try #require(outcome.result.event)
        #expect(event.type == "session_completed")
        #expect(!outcome.result.effects.isEmpty)
        #expect(outcome.result.nextWorkout.sessionId != "a1")
        #expect(outcome.eventLine != nil)
        #expect(outcome.result.newState.lanes["squat.t1"]?.load == "82.5kg")
    }

    private static func passingInput(for item: RenderedItem) -> ItemInput {
        if item.executionContract.recommendedInput == InputMode.amrapFinalSet {
            let target = item.prescription.sets.last?.targetReps ?? 1
            return ItemInput(itemId: item.itemId, mode: InputMode.amrapFinalSet, finalSetReps: target)
        }
        let sets = item.prescription.sets.map { ActualSet(set: $0.set, load: $0.load, reps: $0.targetReps) }
        return ItemInput(itemId: item.itemId, mode: InputMode.perSetReps, sets: sets)
    }
}

import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct SkipExerciseTests {
    private func makeWorkout() async throws -> (URL, LiveWorkout) {
        let dir = try SampleRepo.makeWorkingCopy()
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        return (dir, LiveWorkout(repo: repo, session: session))
    }

    // Skipping a required exercise drops it from the inputs and keeps the finish a partial,
    // which is what the engine requires (it would reject a "complete" missing a required item).
    @Test func skippingRequiredExerciseExcludesItAndStaysPartial() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }

        for item in workout.requiredItems { for set in item.sets { set.logged = true } }
        #expect(workout.allRequiredComplete)

        let skipped = try #require(workout.requiredItems.first)
        skipped.skipped = true

        #expect(!skipped.isComplete)
        #expect(!workout.allRequiredComplete)
        #expect(workout.finishStatus == ExecutionStatus.partial)

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        #expect(input.status == ExecutionStatus.partial)
        #expect(!input.inputs.contains { $0.itemId == skipped.id })
    }

    // The cursor — the single source of truth for the current set in the app and the Live
    // Activity — steps over a skipped exercise to the next one.
    @Test func cursorSkipsOverSkippedExercise() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        #expect(controller.currentTarget?.item.id == first.id)

        controller.setSkipped(first, true)
        #expect(controller.isCurrentExercise(first) == false)
        #expect(controller.currentTarget?.item.id != first.id)

        controller.setSkipped(first, false)
        #expect(controller.currentTarget?.item.id == first.id)
    }
}

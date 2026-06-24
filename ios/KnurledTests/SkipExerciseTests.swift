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

    // Skipping an untouched required exercise drops it from the inputs and keeps the finish a
    // partial, which is what the engine requires (it would reject a "complete" missing a
    // required item).
    @Test func skippingRequiredExerciseExcludesItAndStaysPartial() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }

        let skipped = try #require(workout.requiredItems.first)
        for item in workout.requiredItems where item.id != skipped.id {
            for set in item.sets { set.logged = true }
        }
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

    @Test func bypassedWarmupsDisappearAfterLaterWarmupIsDone() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.items.first { $0.warmups.count > 1 })

        item.warmups[0].bypassed = true
        #expect(item.visibleWarmups.map(\.id) == item.warmups.map(\.id))

        item.warmups[1].logged = true
        #expect(item.visibleWarmups.map(\.id) == Array(item.warmups.dropFirst()).map(\.id))

        item.warmups[1].logged = false
        #expect(item.visibleWarmups.map(\.id) == item.warmups.map(\.id))
    }

    @Test func skippedExerciseWithAnySetActivityShowsPartialState() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.items.first { !$0.warmups.isEmpty })

        item.skipped = true
        #expect(item.skippedState == .skipped)

        item.warmups[0].logged = true
        #expect(item.skippedState == .partial)
    }

    @Test func undoAfterPartialWarmupSkipReturnsCursorToExercise() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first { !$0.warmups.isEmpty })
        #expect(controller.currentTarget?.item.id == first.id)

        controller.logCurrentSet()
        controller.setSkipped(first, true)
        #expect(controller.currentTarget?.item.id != first.id)
        #expect(first.skippedState == .partial)

        controller.setSkipped(first, false)
        #expect(controller.currentTarget?.item.id == first.id)
    }

    @Test func skippingRestOfPartiallyLoggedExercisePreservesLoggedSets() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.requiredItems.first)

        item.sets[0].logged = true
        item.skipped = true

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        let itemInput = try #require(input.inputs.first { $0.itemId == item.id })
        #expect(input.status == ExecutionStatus.partial)
        #expect(itemInput.sets.map(\.set) == [item.sets[0].id])
    }
}

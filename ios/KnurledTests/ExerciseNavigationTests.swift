import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct ExerciseNavigationTests {
    private func makeWorkout() async throws -> (URL, LiveWorkout) {
        let dir = try SampleRepo.makeWorkingCopy()
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        return (dir, LiveWorkout(repo: repo, session: session))
    }

    // Tapping an exercise focuses it, moving the single cursor (shared by the app and the Live
    // Activity) onto its first unlogged set so sets can be done out of order.
    @Test func focusingExerciseMovesCursorOntoIt() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        let second = try #require(workout.items.dropFirst().first)
        #expect(controller.currentTarget?.item.id == first.id)

        controller.focus(second)
        #expect(controller.isCurrentExercise(second))
        #expect(controller.currentTarget?.item.id == second.id)
    }

    // Once the focused exercise is finished the manual focus drops and the cursor returns to the
    // first exercise still outstanding (here, the one that was skipped over).
    @Test func cursorReturnsToFirstIncompleteAfterFocusedCompletes() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        let second = try #require(workout.items.dropFirst().first)

        controller.focus(second)
        var guardCount = 0
        while controller.currentTarget?.item.id == second.id, guardCount < 50 {
            controller.logCurrentSet()
            guardCount += 1
        }

        #expect(second.isComplete)
        #expect(controller.focusedItemID == nil)
        #expect(controller.currentTarget?.item.id == first.id)
    }

    // Focusing an already-finished exercise does nothing — there's nothing left to do there.
    @Test func focusingCompletedExerciseIsNoOp() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        for set in first.warmups { set.logged = true }
        for set in first.sets { set.logged = true }
        #expect(first.isComplete)

        let before = controller.currentTarget?.item.id
        controller.focus(first)
        #expect(controller.focusedItemID == nil)
        #expect(controller.currentTarget?.item.id == before)
    }

    // An exercise the user never started (its equipment was busy, say) is omitted from the inputs
    // and, if it's required, keeps the finish a partial — what skipping used to guarantee.
    @Test func untouchedRequiredExerciseIsOmittedAndStaysPartial() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }

        let untouched = try #require(workout.requiredItems.first)
        for item in workout.requiredItems where item.id != untouched.id {
            for set in item.sets { set.logged = true }
        }

        #expect(!untouched.isComplete)
        #expect(!workout.allRequiredComplete)
        #expect(workout.finishStatus == ExecutionStatus.partial)

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        #expect(input.status == ExecutionStatus.partial)
        #expect(!input.inputs.contains { $0.itemId == untouched.id })
    }

    // A partially logged exercise sends only the sets actually recorded, so an in-progress
    // exercise isn't dropped when the equipment frees up later or the workout is finished early.
    @Test func partiallyLoggedExercisePreservesLoggedSets() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.requiredItems.first)

        item.sets[0].logged = true

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        let itemInput = try #require(input.inputs.first { $0.itemId == item.id })
        #expect(input.status == ExecutionStatus.partial)
        #expect(itemInput.sets.map(\.set) == [item.sets[0].id])
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
}

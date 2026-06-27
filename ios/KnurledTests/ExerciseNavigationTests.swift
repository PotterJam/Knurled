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

    // Once an out-of-order exercise is finished the cursor continues forward from that exercise,
    // leaving earlier untouched exercises skipped unless the user explicitly comes back to them.
    @Test func cursorAdvancesAfterFocusedExerciseCompletes() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        let second = try #require(workout.items.dropFirst().first)
        let third = try #require(workout.items.dropFirst(2).first)

        controller.focus(second)
        var guardCount = 0
        while controller.currentTarget?.item.id == second.id, guardCount < 50 {
            controller.logCurrentSet()
            guardCount += 1
        }

        #expect(second.isComplete)
        #expect(!first.isComplete)
        #expect(controller.currentTarget?.item.id == third.id)
    }

    @Test func tickingLaterWarmupAdvancesForwardThroughWarmups() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let item = try #require(workout.items.first { $0.warmups.count > 1 })
        let skipped = item.warmups[0]
        let later = item.warmups[1]
        let expectedNext = item.warmups.dropFirst(2).first ?? item.sets.first

        controller.toggle(set: later, in: item)

        #expect(!skipped.logged)
        #expect(later.logged)
        #expect(controller.currentTarget?.item.id == item.id)
        #expect(controller.currentTarget?.set === expectedNext)
    }

    @Test func advancingWithinExerciseScrollsToNextSet() {
        let previous = WorkoutScrollTarget(exerciseID: "squat", setID: 2, isWarmup: false)
        let current = WorkoutScrollTarget(exerciseID: "squat", setID: 3, isWarmup: false)

        #expect(
            WorkoutScrollRequest.afterAdvance(from: previous, to: current)
                == WorkoutScrollRequest(destination: .set(current), delayForLayout: false)
        )
    }

    @Test func finishingExerciseScrollsToNextExerciseAfterLayoutSettles() {
        let previous = WorkoutScrollTarget(exerciseID: "squat", setID: 3, isWarmup: false)
        let current = WorkoutScrollTarget(exerciseID: "bench", setID: 1, isWarmup: false)

        #expect(
            WorkoutScrollRequest.afterAdvance(from: previous, to: current)
                == WorkoutScrollRequest(destination: .exercise("bench"), delayForLayout: true)
        )
    }

    @Test func completingAmrapRecordsExplicitReps() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let amrapItem = workout.items.first { $0.isAmrap }
        let item = try #require(amrapItem)
        let set = try #require(item.requiredSets.last)

        controller.completeAmrap(set: set, in: item, reps: 7)

        #expect(set.logged)
        #expect(set.reps == 7)
    }

    @Test func completedAmrapPresentationShowsExactRepsWithoutMarker() {
        let presentation = SetRepsPresentation(
            prescribedReps: 5,
            performedReps: 7,
            isAmrapFinal: true,
            isLogged: true
        )

        #expect(presentation.reps == 7)
        #expect(!presentation.showsAmrapMarker)
    }

    @Test func pendingAmrapPresentationShowsPrescription() {
        let presentation = SetRepsPresentation(
            prescribedReps: 5,
            performedReps: 5,
            isAmrapFinal: true,
            isLogged: false
        )

        #expect(presentation.reps == 5)
        #expect(presentation.showsAmrapMarker)
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

    @Test func movingExerciseChangesCursorOrder() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        let second = try #require(workout.items.dropFirst().first)

        workout.moveItem(from: second.id, before: first.id)

        #expect(workout.items.first?.id == second.id)
        #expect(controller.currentTarget?.item.id == second.id)
    }

    @Test func addedSetDoesNotBlockCompletionButIsLoggedWhenDone() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.requiredItems.first)
        item.addSet()
        let extra = try #require(item.sets.last)

        for set in item.requiredSets { set.logged = true }

        #expect(item.isComplete)
        extra.logged = true
        extra.reps = 12

        let input = item.itemInput()
        #expect(input.sets.contains { $0.set == extra.id && $0.reps == 12 })
        if item.isAmrap {
            #expect(input.finalSetReps == item.requiredSets.last?.reps)
        }
    }

    @Test func addedExerciseIsOptionalAndIncludedWhenLogged() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }

        let extra = workout.addExtraExercise(exercise: "landmine press", load: "20kg", setCount: 2, reps: 12)
        #expect(!workout.requiredItems.contains { $0.id == extra.id })
        #expect(!workout.canSubmit)

        extra.sets[0].logged = true
        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        let extraInput = try #require(input.inputs.first { $0.itemId == extra.id })

        #expect(extraInput.performedExercise == "landmine_press")
        #expect(extraInput.sets.map(\.reps) == [12])
        #expect(input.status == ExecutionStatus.partial)
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
        #expect(workout.canSubmit)
        #expect(workout.canSaveProgress)
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
        #expect(workout.canSubmit)
        #expect(workout.canSaveProgress)
        #expect(input.status == ExecutionStatus.partial)
        #expect(itemInput.sets.map(\.set) == [item.sets[0].id])
    }

    @Test func loggedSetUsesRowLoadRepsAndRPEMetric() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.requiredItems.first)
        let set = try #require(item.sets.first)

        set.load = "82.5kg"
        set.reps = 6
        set.rpe = 8.5
        set.logged = true

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        let itemInput = try #require(input.inputs.first { $0.itemId == item.id })
        let actual = try #require(itemInput.sets.first { $0.set == set.id })

        #expect(actual.load == "82.5kg")
        #expect(actual.reps == 6)
        #expect(actual.metrics["rpe"] == "8.5")
    }

    @Test func savedPartialRecordRestoresLoggedSets() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try #require(workout.requiredItems.first)
        let record = DayRecord(
            date: "2026-06-24",
            status: ExecutionStatus.partial,
            sessionId: workout.session.sessionId,
            savedAt: "2026-06-24T10:45:00Z",
            lifts: [
                LiftRecord(
                    itemId: source.id,
                    exercise: source.item.exercise,
                    weight: "77.5kg",
                    sets: [5, 4]
                ),
            ]
        )

        let restored = LiveWorkout(repo: workout.repo, session: workout.session, restoring: record)
        let restoredItem = try #require(restored.items.first { $0.id == source.id })

        #expect(restored.startedAt == "2026-06-24T10:45:00Z")
        #expect(restoredItem.sets[0].logged)
        #expect(restoredItem.sets[0].reps == 5)
        #expect(restoredItem.sets[0].load == "77.5kg")
        #expect(restoredItem.sets[1].logged)
        #expect(restoredItem.sets[1].reps == 4)
        #expect(!restoredItem.sets[2].logged)
        #expect(restored.canSubmit)
        #expect(restored.canSaveProgress)
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

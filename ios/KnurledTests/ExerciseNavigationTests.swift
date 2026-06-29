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

    @Test func finishingPreventsViewTeardownFromRecreatingTheDraft() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.discard()
        controller.begin(workout)
        defer { controller.discard() }
        controller.persistDraftNow()
        #expect(DraftStore.shared.hasDraft)

        controller.finish()
        controller.persistDraftNow() // Mirrors ActiveWorkoutView.onDisappear.

        #expect(!DraftStore.shared.hasDraft)
    }

    @Test func committedWorkoutRemovesAResurrectedLocalDraft() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.discard()
        controller.begin(workout)
        defer { controller.discard() }
        controller.persistDraftNow()
        let record = TrainingRecord(
            id: "finished-workout",
            date: "2026-06-29",
            sessionId: workout.session.sessionId,
            startedAt: workout.startedAt,
            completedAt: "2026-06-29T11:00:00Z",
            lifts: []
        )

        let draft = DraftStore.shared.loadUncommitted(records: [record])

        #expect(draft == nil)
        #expect(!DraftStore.shared.hasDraft)
    }

    @Test func firstWeightEntryPropagatesTheCompleteValueToEverySet() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.items.first)
        let editedSet = try #require(item.sets.first)
        for set in item.sets { set.load = nil }

        var draft = LoadEditDraft(baselineText: "", seedsWholeExercise: true)
        draft.destinationText = "5"
        draft.applyDestination(to: editedSet, in: item, units: .kg)
        draft.destinationText = "55"
        draft.applyDestination(to: editedSet, in: item, units: .kg)

        #expect(item.sets.allSatisfy { $0.load == "55kg" })
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

    @Test func reloadFallbackDoesNotReturnEarlierSkippedWarmup() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let item = try #require(workout.items.first { $0.warmups.count > 2 })
        let first = item.warmups[0]
        let later = item.warmups[2]

        controller.toggle(set: first, in: item)
        controller.toggle(set: later, in: item)

        let draft = WorkoutDraft(
            renderedSessionHash: workout.session.renderedSessionHash,
            sessionId: workout.session.sessionId,
            displayName: workout.session.displayName,
            session: workout.session,
            unitsRaw: workout.units.rawValue,
            startedAt: workout.startedAt,
            savedAt: "2026-06-29T10:00:00Z",
            items: workout.draftItems(),
            focusedItemID: nil,
            cursorItemID: nil,
            cursorSetID: nil,
            cursorSetIsWarmup: nil,
            cursorAtEnd: false
        )
        let restored = LiveWorkout(repo: workout.repo, session: workout.session, draft: draft)
        controller.begin(restored, resumingFrom: draft)

        let restoredItem = try #require(restored.items.first { $0.id == item.id })
        let restoredExpectedNext = restoredItem.warmups.dropFirst(3).first ?? restoredItem.sets.first
        #expect(restoredItem.warmups[0].logged)
        #expect(restoredItem.warmups[1].bypassed)
        #expect(restoredItem.warmups[2].logged)
        #expect(controller.currentTarget?.item.id == restoredItem.id)
        #expect(controller.currentTarget?.set === restoredExpectedNext)
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

    // Switching back to a finished exercise re-focuses it (e.g. to fix a log or add another set),
    // landing the cursor on its last set so the card and Live Activity follow.
    @Test func focusingCompletedExerciseSwitchesBackToIt() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = WorkoutLiveController.shared
        controller.begin(workout)
        defer { controller.end() }

        let first = try #require(workout.items.first)
        let second = try #require(workout.items.dropFirst().first)
        for set in first.warmups { set.logged = true }
        for set in first.sets { set.logged = true }
        #expect(first.isComplete)

        // Move the cursor off the finished exercise, then switch back to it.
        controller.focus(second)
        #expect(controller.currentTarget?.item.id == second.id)

        controller.focus(first)
        #expect(controller.focusedItemID == first.id)
        #expect(controller.isCurrentExercise(first))
        #expect(controller.currentTarget?.set === first.sets.last)
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
        #expect(input.completedAt == "2026-06-24T11:00:00Z")
    }

    // An exercise the user never started (its equipment was busy, say) is omitted from the
    // finalized workout — what skipping used to guarantee.
    @Test func untouchedRequiredExerciseIsOmittedFromFinalizedWorkout() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }

        let untouched = try #require(workout.requiredItems.first)
        for item in workout.requiredItems where item.id != untouched.id {
            for set in item.sets { set.logged = true }
        }

        #expect(!untouched.isComplete)
        #expect(!workout.allRequiredComplete)
        #expect(workout.canSubmit)

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        #expect(input.completedAt == "2026-06-24T11:00:00Z")
        #expect(!input.inputs.contains { $0.itemId == untouched.id })
    }

    // A partly logged exercise sends only the sets actually recorded.
    @Test func partiallyLoggedExercisePreservesLoggedSets() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(workout.requiredItems.first)

        item.sets[0].logged = true

        let input = workout.finishInput(timestamp: "2026-06-24T11:00:00Z")
        let itemInput = try #require(input.inputs.first { $0.itemId == item.id })
        #expect(workout.canSubmit)
        #expect(input.completedAt == "2026-06-24T11:00:00Z")
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

    @Test func workoutRecordRestoresLoggedSetsForEditing() async throws {
        let (dir, workout) = try await makeWorkout()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try #require(workout.requiredItems.first)
        let record = TrainingRecord(
            id: "workout-1",
            date: "2026-06-24",
            sessionId: workout.session.sessionId,
            startedAt: "2026-06-24T10:00:00Z",
            completedAt: "2026-06-24T10:45:00Z",
            lifts: [
                LiftRecord(
                    liftId: "source-1",
                    itemId: source.id,
                    exercise: source.item.exercise,
                    weight: "77.5kg",
                    sets: [5, 4]
                ),
            ]
        )

        let restored = LiveWorkout(repo: workout.repo, session: workout.session, restoring: record)
        let restoredItem = try #require(restored.items.first { $0.id == source.id })

        #expect(restored.startedAt == "2026-06-24T10:00:00Z")
        #expect(restoredItem.sets[0].logged)
        #expect(restoredItem.sets[0].reps == 5)
        #expect(restoredItem.sets[0].load == "77.5kg")
        #expect(restoredItem.sets[1].logged)
        #expect(restoredItem.sets[1].reps == 4)
        #expect(!restoredItem.sets[2].logged)
        #expect(restored.canSubmit)
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

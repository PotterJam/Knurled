import ActivityKit
import Foundation
import Observation

/// Single source of truth for the live workout while it is being performed. Owns the rest
/// countdown and the Live Activity, and exposes the actions the interactive widget intents
/// (LogSet / SkipRest / AddRest / AmrapStep) call from the app process.
///
/// The active `LiveWorkout` instance is shared with `ActiveWorkoutView`, so set changes made
/// in-app and from the lock screen mutate the same observable model and stay in sync.
@MainActor
@Observable
final class WorkoutLiveController {
    static let shared = WorkoutLiveController()

    private struct ActivityHandle: @unchecked Sendable {
        let activity: Activity<RestActivityAttributes>

        func update(_ content: ActivityContent<RestActivityAttributes.ContentState>) async {
            await activity.update(content)
        }

        func end(dismissalPolicy: ActivityUIDismissalPolicy) async {
            await activity.end(nil, dismissalPolicy: dismissalPolicy)
        }
    }

    private(set) var workout: LiveWorkout?
    /// The exercise the user has tapped to work on next. Equipment is often busy, so sets get done
    /// out of order: tapping an unfocused card focuses it here and moves the cursor onto its first
    /// unlogged set. Cleared (falling back to the first incomplete exercise) once it's finished.
    private(set) var focusedItemID: String?
    private(set) var restEndDate: Date?
    /// Staged rep count for the current AMRAP final set (adjusted via the widget stepper).
    private(set) var amrapReps: Int = 0

    private var now: Date = .now
    private var tickTask: Task<Void, Never>?
    private var activity: ActivityHandle?

    private init() {}

    // MARK: - Rest countdown (read by the in-app RestTimerBar)

    var isResting: Bool { remaining > 0 }

    var remaining: TimeInterval {
        guard let restEndDate else { return 0 }
        return max(0, restEndDate.timeIntervalSince(now))
    }

    var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Cursor

    /// The next set the user should perform. If the user has tapped an exercise to focus it, the
    /// cursor sits on that exercise's first unlogged set; otherwise it's the first unlogged set in
    /// item/set order. This single cursor drives both the in-app card highlighting and the Live
    /// Activity, so the "current set" is the same everywhere and advances together.
    var currentTarget: (item: LiveItem, set: LiveSet)? {
        guard let workout else { return nil }
        if let focusedItemID,
           let item = workout.items.first(where: { $0.id == focusedItemID }),
           let set = nextSet(in: item) {
            return (item, set)
        }
        for item in workout.items {
            if let set = nextSet(in: item) { return (item, set) }
        }
        return nil
    }

    /// The first set still to do within an exercise: an un-bypassed, unlogged warmup, then the
    /// first unlogged working set. `nil` once everything in the exercise is done.
    private func nextSet(in item: LiveItem) -> LiveSet? {
        for set in item.warmups where !set.logged && !set.bypassed { return set }
        for set in item.sets where !set.logged { return set }
        return nil
    }

    /// Whether `set` is the single active set across the whole workout. Compared by object
    /// identity because a warmup and a working set within the same exercise can share a set
    /// number (both number from 1).
    func isCurrent(_ set: LiveSet) -> Bool {
        currentTarget?.set === set
    }

    /// Whether `item` holds the current set (the exercise the user is on right now).
    func isCurrentExercise(_ item: LiveItem) -> Bool {
        currentTarget?.item.id == item.id
    }

    private func isAmrapTarget(_ item: LiveItem, _ set: LiveSet) -> Bool {
        !set.isWarmup && item.isAmrap && set.id == item.sets.last?.id
    }

    // MARK: - Lifecycle

    func begin(_ workout: LiveWorkout) {
        end()
        self.workout = workout
        syncAmrap()
        startActivity()
    }

    func end() {
        stopRest()
        workout = nil
        focusedItemID = nil
        endActivity()
    }

    // MARK: - Actions from the Live Activity

    func logCurrentSet() {
        guard let (item, set) = currentTarget else { return }
        set.reps = isAmrapTarget(item, set) ? amrapReps : set.prescribed.targetReps
        set.logged = true
        afterLog(item: item, wasWarmup: set.isWarmup)
    }

    func toggle(set: LiveSet, in item: LiveItem) {
        if set.logged {
            set.logged = false
            set.bypassed = false
            syncAmrap()
            updateActivity()
            return
        }

        set.bypassed = false
        set.logged = true
        afterLog(item: item, wasWarmup: set.isWarmup)
    }

    /// Advance past the current warmup without recording it as performed. Warmups are
    /// guidance-only, so this moves the cursor through the ramp without touching progression.
    func advanceCurrentWarmup() {
        guard let (_, set) = currentTarget, set.isWarmup else { return }
        set.logged = false
        set.bypassed = true
        syncAmrap()
        stopRest()
        updateActivity()
    }

    /// Jump into the warmup ramp at a later set, marking earlier warmups as bypassed rather than
    /// logged. Later warmups stay available if the user wants only the top of the ramp.
    func startWarmups(at selected: LiveSet, in item: LiveItem) {
        guard selected.isWarmup else { return }
        for warmup in item.warmups {
            if warmup.id < selected.id && !warmup.logged {
                warmup.logged = false
                warmup.bypassed = true
            } else {
                warmup.bypassed = false
            }
        }
        syncAmrap()
        stopRest()
        updateActivity()
    }

    func adjustAmrap(delta: Int) {
        guard let (item, set) = currentTarget, isAmrapTarget(item, set) else { return }
        amrapReps = max(0, amrapReps + delta)
        updateActivity()
    }

    func skipRest() {
        stopRest()
        updateActivity()
    }

    func addRest(_ seconds: Int) {
        guard let restEndDate else { return }
        now = .now
        self.restEndDate = max(now.addingTimeInterval(1), restEndDate.addingTimeInterval(TimeInterval(seconds)))
        updateActivity()
    }

    // MARK: - Notifications from the in-app UI

    /// Called after a set is logged in-app; starts rest before the next set (matching the
    /// previous in-app behaviour) and refreshes the activity.
    func didLogSetInApp(item: LiveItem, wasWarmup: Bool = false) {
        clearFocusIfDone()
        syncAmrap()
        if currentTarget != nil, !wasWarmup {
            startRest(seconds: item.item.rest.seconds)
        } else {
            stopRest()
            updateActivity()
        }
    }

    /// Called after any other in-app set change (undo, missed, edit) to keep the activity fresh.
    func modelChanged() {
        syncAmrap()
        updateActivity()
    }

    /// Move the cursor onto `item` because the user tapped it (e.g. its equipment is free now).
    /// The current set becomes its first unlogged set; if it's already done this is a no-op.
    func focus(_ item: LiveItem) {
        guard nextSet(in: item) != nil else { return }
        focusedItemID = item.id
        syncAmrap()
        stopRest()
        updateActivity()
    }

    // MARK: - Internals

    private func afterLog(item: LiveItem, wasWarmup: Bool) {
        clearFocusIfDone()
        syncAmrap()
        if currentTarget != nil, !wasWarmup {
            startRest(seconds: item.item.rest.seconds)
        } else {
            stopRest()
            updateActivity()
        }
    }

    /// Once the focused exercise has nothing left to do, drop the manual focus so the cursor
    /// returns to the first exercise still outstanding.
    private func clearFocusIfDone() {
        guard let focusedItemID,
              let item = workout?.items.first(where: { $0.id == focusedItemID }) else { return }
        if nextSet(in: item) == nil { self.focusedItemID = nil }
    }

    private func syncAmrap() {
        if let (item, set) = currentTarget, isAmrapTarget(item, set) {
            amrapReps = set.reps
        } else {
            amrapReps = 0
        }
    }

    private func startRest(seconds: Int) {
        now = .now
        restEndDate = now.addingTimeInterval(TimeInterval(max(1, seconds)))
        startTicker()
        updateActivity()
    }

    private func stopRest() {
        tickTask?.cancel()
        tickTask = nil
        restEndDate = nil
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.restEndDate != nil else { return }
                self.now = .now
                if self.remaining <= 0 {
                    self.stopRest()
                    self.updateActivity()
                }
            }
        }
    }

    // MARK: - Live Activity

    private func contentState() -> RestActivityAttributes.ContentState? {
        guard let workout else { return nil }
        let totalExercises = workout.items.count
        guard let (item, set) = currentTarget else {
            return RestActivityAttributes.ContentState(
                phase: .finished, exerciseTitle: "Workout complete",
                exerciseIndex: totalExercises, totalExercises: totalExercises,
                setNumber: 0, totalSets: 0, targetReps: 0, loadText: nil,
                isWarmup: false, isAmrap: false, amrapReps: 0, restEndDate: now
            )
        }
        let index = (workout.items.firstIndex { $0.id == item.id } ?? 0) + 1
        return RestActivityAttributes.ContentState(
            phase: isResting ? .resting : .ready,
            exerciseTitle: item.item.display.title,
            exerciseIndex: index,
            totalExercises: totalExercises,
            setNumber: set.id,
            totalSets: set.isWarmup ? item.warmups.count : item.sets.count,
            targetReps: set.prescribed.targetReps,
            loadText: set.load,
            isWarmup: set.isWarmup,
            isAmrap: isAmrapTarget(item, set),
            amrapReps: amrapReps,
            restEndDate: restEndDate ?? now
        )
    }

    private func startActivity() {
        endActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let workout, let state = contentState() else { return }
        let attributes = RestActivityAttributes(workoutName: workout.session.displayName)
        activity = try? ActivityHandle(activity: Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: staleDate())
        ))
    }

    private func updateActivity() {
        guard let activity, let state = contentState() else { return }
        let content = ActivityContent(state: state, staleDate: staleDate())
        Task { await activity.update(content) }
    }

    private func endActivity() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(dismissalPolicy: .immediate) }
    }

    private func staleDate() -> Date? { isResting ? restEndDate : nil }
}

import ActivityKit
import Foundation
import Observation

struct WorkoutScrollTarget: Hashable {
    let exerciseID: String
    let setID: Int
    let isWarmup: Bool
}

enum WorkoutScrollDestination: Hashable {
    case exercise(String)
    case set(WorkoutScrollTarget)
}

struct WorkoutScrollRequest: Equatable {
    let destination: WorkoutScrollDestination
    let delayForLayout: Bool

    /// A set-to-set advance can target the next row immediately. Completing an exercise changes
    /// the card's layout, so target the next exercise only after that layout has settled.
    static func afterAdvance(
        from previous: WorkoutScrollTarget,
        to current: WorkoutScrollTarget
    ) -> WorkoutScrollRequest {
        if previous.exerciseID == current.exerciseID {
            return WorkoutScrollRequest(destination: .set(current), delayForLayout: false)
        }
        return WorkoutScrollRequest(destination: .exercise(current.exerciseID), delayForLayout: true)
    }
}

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
    /// The exercise holding the current cursor. Equipment is often busy, so sets get done out of
    /// order: tapping a card focuses it, and logging a set advances forward from that set.
    private(set) var focusedItemID: String?
    private var preferredTarget: TargetRef?
    private var cursorAtEnd = false
    private(set) var restEndDate: Date?
    /// Staged rep count for the current AMRAP final set (adjusted via the widget stepper).
    private(set) var amrapReps: Int = 0

    private var now: Date = .now
    private var restTimersEnabled = true
    private var tickTask: Task<Void, Never>?
    private var activity: ActivityHandle?

    private init() {}

    private struct TargetRef: Equatable {
        let itemID: String
        let setID: ObjectIdentifier
    }

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

    /// The next set the user should perform. After a set is logged, the cursor advances from that
    /// exact set instead of jumping back to earlier skipped work; otherwise it starts at the first
    /// unlogged set in item/set order. This single cursor drives both the in-app card highlighting
    /// and the Live Activity, so the "current set" is the same everywhere and advances together.
    var currentTarget: (item: LiveItem, set: LiveSet)? {
        guard let workout else { return nil }
        if let preferredTarget,
           let target = resolve(preferredTarget) {
            return target
        }
        if cursorAtEnd { return nil }
        if let focusedItemID,
           let item = workout.items.first(where: { $0.id == focusedItemID }),
           let set = resumeSet(in: item) {
            return (item, set)
        }
        for item in workout.items {
            if let set = nextSet(in: item) { return (item, set) }
        }
        return nil
    }

    var currentScrollTarget: WorkoutScrollTarget? {
        guard let (item, set) = currentTarget else { return nil }
        return WorkoutScrollTarget(exerciseID: item.id, setID: set.id, isWarmup: set.isWarmup)
    }

    /// The first set still to do within an exercise: an un-bypassed, unlogged warmup, then the
    /// first unlogged working set. `nil` once everything in the exercise is done.
    private func nextSet(in item: LiveItem) -> LiveSet? {
        for set in item.warmups where !set.logged && !set.bypassed { return set }
        for set in item.sets where !set.logged { return set }
        return nil
    }

    /// Where to resume an exercise the user comes back to. If they've already logged something
    /// here, continue from *after* the last set they did rather than snapping back to an earlier
    /// set they skipped (e.g. a warmup they deliberately passed). With nothing logged yet, this is
    /// just the first set.
    private func resumeSet(in item: LiveItem) -> LiveSet? {
        let ordered = item.warmups + item.sets
        guard let lastLogged = ordered.lastIndex(where: { $0.logged }) else {
            return nextSet(in: item)
        }
        for set in ordered.dropFirst(lastLogged + 1) where !set.logged && !set.bypassed {
            return set
        }
        return nil
    }

    private func resolve(_ target: TargetRef) -> (item: LiveItem, set: LiveSet)? {
        guard let item = workout?.items.first(where: { $0.id == target.itemID }) else { return nil }
        for set in item.warmups + item.sets
            where ObjectIdentifier(set) == target.setID && !set.logged && !set.bypassed {
            return (item, set)
        }
        return nil
    }

    private func ref(for item: LiveItem, set: LiveSet) -> TargetRef {
        TargetRef(itemID: item.id, setID: ObjectIdentifier(set))
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
        !set.isWarmup && item.isAmrap && set.id == item.lastRequiredSetID
    }

    // MARK: - Lifecycle

    func begin(_ workout: LiveWorkout, restTimersEnabled: Bool = true) {
        end()
        self.workout = workout
        self.restTimersEnabled = restTimersEnabled
        syncAmrap()
        startActivity()
    }

    func setRestTimersEnabled(_ enabled: Bool) {
        restTimersEnabled = enabled
        if !enabled {
            stopRest()
            updateActivity()
        }
    }

    func end() {
        stopRest()
        workout = nil
        focusedItemID = nil
        preferredTarget = nil
        cursorAtEnd = false
        endActivity()
    }

    // MARK: - Actions from the Live Activity

    func logCurrentSet() {
        guard let (item, set) = currentTarget else { return }
        set.reps = isAmrapTarget(item, set) ? amrapReps : set.prescribed.targetReps
        set.logged = true
        afterLog(item: item, set: set)
    }

    func toggle(set: LiveSet, in item: LiveItem) {
        if set.logged {
            set.logged = false
            set.bypassed = false
            preferredTarget = ref(for: item, set: set)
            focusedItemID = item.id
            cursorAtEnd = false
            syncAmrap()
            updateActivity()
            return
        }

        set.bypassed = false
        set.logged = true
        afterLog(item: item, set: set)
    }

    /// Records the exact result for an AMRAP set after the user confirms the rep count.
    func completeAmrap(set: LiveSet, in item: LiveItem, reps: Int) {
        guard !set.logged, isAmrapTarget(item, set) else { return }
        set.reps = max(0, reps)
        set.bypassed = false
        set.logged = true
        afterLog(item: item, set: set)
    }

    /// Advance past the current warmup without recording it as performed. Warmups are
    /// guidance-only, so this moves the cursor through the ramp without touching progression.
    func advanceCurrentWarmup() {
        guard let (item, set) = currentTarget, set.isWarmup else { return }
        set.logged = false
        set.bypassed = true
        moveCursorAfter(item: item, set: set)
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
        preferredTarget = ref(for: item, set: selected)
        focusedItemID = item.id
        cursorAtEnd = false
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

    /// Legacy in-app notification hook. Main set rows now call `toggle(set:in:)`, which has the
    /// set identity needed to advance the cursor precisely.
    func didLogSetInApp(item: LiveItem, wasWarmup: Bool = false) {
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
        guard let set = resumeSet(in: item) else { return }
        focusedItemID = item.id
        preferredTarget = ref(for: item, set: set)
        cursorAtEnd = false
        syncAmrap()
        stopRest()
        updateActivity()
    }

    // MARK: - Internals

    private func afterLog(item: LiveItem, set: LiveSet) {
        moveCursorAfter(item: item, set: set)
        syncAmrap()
        // Ramp-up sets and whole warm-up exercises are guidance only — no rest countdown between them.
        if currentTarget != nil, !set.isWarmup, !item.isSessionWarmup {
            startRest(seconds: item.item.rest.seconds)
        } else {
            stopRest()
            updateActivity()
        }
    }

    /// After logging out of order, keep moving forward from the set the user just performed
    /// instead of jumping back to earlier skipped sets or warmups.
    private func moveCursorAfter(item: LiveItem, set loggedSet: LiveSet) {
        guard let workout,
              let itemIndex = workout.items.firstIndex(where: { $0.id == item.id }) else {
            preferredTarget = nil
            focusedItemID = nil
            cursorAtEnd = false
            return
        }

        if let set = nextSet(in: item, after: loggedSet) {
            preferredTarget = ref(for: item, set: set)
            focusedItemID = item.id
            cursorAtEnd = false
            return
        }

        for laterItem in workout.items.dropFirst(itemIndex + 1) {
            if let set = nextSet(in: laterItem) {
                preferredTarget = ref(for: laterItem, set: set)
                focusedItemID = laterItem.id
                cursorAtEnd = false
                return
            }
        }

        preferredTarget = nil
        focusedItemID = nil
        cursorAtEnd = true
    }

    private func nextSet(in item: LiveItem, after loggedSet: LiveSet) -> LiveSet? {
        let orderedSets = item.warmups + item.sets
        guard let loggedIndex = orderedSets.firstIndex(where: { $0 === loggedSet }) else {
            return nextSet(in: item)
        }
        for set in orderedSets.dropFirst(loggedIndex + 1) where !set.logged && !set.bypassed {
            return set
        }
        return nil
    }

    private func syncAmrap() {
        if let (item, set) = currentTarget, isAmrapTarget(item, set) {
            amrapReps = set.reps
        } else {
            amrapReps = 0
        }
    }

    private func startRest(seconds: Int) {
        guard restTimersEnabled else {
            stopRest()
            updateActivity()
            return
        }
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

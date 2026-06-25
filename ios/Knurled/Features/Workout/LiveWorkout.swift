import Foundation
import Observation

enum AdjustScope: CaseIterable, Hashable {
    case thisSet
    case remaining
    case wholeExercise

    var title: String {
        switch self {
        case .thisSet: "This set only"
        case .remaining: "Remaining sets"
        case .wholeExercise: "Whole exercise"
        }
    }
}

@MainActor
@Observable
final class LiveSet: Identifiable {
    let id: Int
    let prescribed: PrescribedSet
    /// Warmup ramp-up sets share the same row UI but are never logged to the engine, never
    /// gate completion, and (unlike working sets) don't start a rest countdown.
    let isWarmup: Bool
    var reps: Int
    var load: String?
    var logged: Bool
    /// Warmups are guidance-only, so a user can advance past an early ramp set without
    /// recording it as performed. Bypassed warmups are ignored by the active cursor.
    var bypassed: Bool

    init(prescribed: PrescribedSet, defaultLoad: String?, isWarmup: Bool = false) {
        self.id = prescribed.set
        self.prescribed = prescribed
        self.isWarmup = isWarmup
        self.reps = prescribed.targetReps
        self.load = defaultLoad ?? prescribed.load
        self.logged = false
        self.bypassed = false
    }

    var isAdjusted: Bool {
        load != prescribed.load
    }
}

@MainActor
@Observable
final class LiveItem: Identifiable {
    let id: String
    let item: RenderedItem
    let units: Units
    var warmups: [LiveSet]
    var sets: [LiveSet]
    var todayLoad: String?
    var performedExercise: String?
    var swapLabel: String?
    var swapPolicy: SwapPolicy?

    init(item: RenderedItem, units: Units) {
        self.id = item.itemId
        self.item = item
        self.units = units
        self.warmups = item.prescription.warmups.map { LiveSet(prescribed: $0, defaultLoad: $0.load, isWarmup: true) }
        self.sets = item.prescription.sets.map { LiveSet(prescribed: $0, defaultLoad: $0.load) }
    }

    var hasWarmups: Bool { !warmups.isEmpty }

    var mode: String { item.executionContract.recommendedInput }
    var isAmrap: Bool { item.executionContract.recommendedInput == InputMode.amrapFinalSet }
    var required: Bool { item.executionContract.requiredForCompletion }
    var prescribedLoad: String? { item.prescription.sets.first?.load }
    var currentLoad: String? { todayLoad ?? sets.first?.load ?? prescribedLoad }
    var isComplete: Bool { sets.allSatisfy(\.logged) }
    var anyLogged: Bool { sets.contains(where: \.logged) }
    var isAdjusted: Bool { sets.contains(where: \.isAdjusted) }
    var visibleWarmups: [LiveSet] {
        guard warmups.contains(where: \.logged) else { return warmups }
        return warmups.filter { !$0.bypassed }
    }

    var options: RenderedExerciseOptions? { item.exerciseOptions }
    var canSwap: Bool {
        guard let options else { return false }
        return options.allowRuntimeSwap && !options.alternatives.isEmpty
    }
    var isSwapped: Bool { performedExercise != nil }
    var prescribedExerciseName: String { Self.titleCase(item.exercise) }
    var performedExerciseName: String { swapLabel ?? Self.titleCase(performedExercise ?? item.exercise) }

    func swap(to alternative: ExerciseAlternative) {
        performedExercise = alternative.exercise
        swapLabel = alternative.label
        swapPolicy = alternative.policy
        ensureBaseLoad(for: alternative.exercise)
    }

    func clearSwap() {
        performedExercise = nil
        swapLabel = nil
        swapPolicy = nil
    }

    func ensureBaseLoad(for exercise: String? = nil) {
        guard sets.allSatisfy({ $0.load == nil }) else { return }
        adjust(
            load: Self.defaultBaseLoad(for: exercise ?? performedExercise ?? item.exercise, units: units),
            scope: .wholeExercise,
            from: sets.first?.id ?? 1
        )
    }

    func restore(from lift: LiftRecord) {
        if Self.normalized(lift.exercise) != Self.normalized(item.exercise) {
            performedExercise = lift.exercise
            if let alternative = item.exerciseOptions?.alternatives.first(where: {
                Self.normalized($0.exercise) == Self.normalized(lift.exercise)
            }) {
                swapLabel = alternative.label
                swapPolicy = alternative.policy
            }
        }

        if let weight = lift.weight {
            adjust(load: weight, scope: .wholeExercise, from: sets.first?.id ?? 1)
        }

        for (index, reps) in lift.sets.enumerated() where index < sets.count {
            sets[index].reps = reps
            sets[index].logged = true
        }
    }

    static func titleCase(_ exercise: String) -> String {
        exercise.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func normalized(_ exercise: String) -> String {
        exercise.replacingOccurrences(of: " ", with: "_").lowercased()
    }

    func adjust(load: String?, scope: AdjustScope, from setNumber: Int) {
        switch scope {
        case .thisSet:
            sets.first { $0.id == setNumber }?.load = load
        case .remaining:
            for set in sets where set.id >= setNumber { set.load = load }
        case .wholeExercise:
            for set in sets { set.load = load }
        }
        todayLoad = load
    }

    static func defaultBaseLoad(for exercise: String, units: Units) -> String {
        if isBodyweightExercise(exercise) {
            return "0\(units.rawValue)"
        }

        return switch units {
        case .kg: "20kg"
        case .lb: "45lb"
        }
    }

    static func isBodyweightExercise(_ exercise: String) -> Bool {
        let normalized = normalized(exercise)
        return normalized.contains("pull_up")
            || normalized.contains("pullup")
            || normalized.contains("chin_up")
            || normalized.contains("chinup")
    }

    /// Optional work that was started but not completed still sends its logged sets, so a user
    /// can record extra work without making it part of completion gating.
    func partialInput() -> ItemInput {
        ItemInput(
            itemId: id,
            mode: InputMode.perSetReps,
            sets: sets.filter(\.logged).map { ActualSet(set: $0.id, load: $0.load, reps: $0.reps) },
            performedExercise: performedExercise,
            swapReason: isSwapped ? "preferred alternative" : nil,
            swapPolicy: swapPolicy
        )
    }

    func itemInput() -> ItemInput {
        let performed = performedExercise
        let reason = isSwapped ? "preferred alternative" : nil
        if isAmrap {
            let overrideLoad = sets.first { $0.isAdjusted }?.load
            return ItemInput(
                itemId: id,
                mode: InputMode.amrapFinalSet,
                finalSetReps: sets.last?.reps ?? 0,
                load: overrideLoad,
                performedExercise: performed,
                swapReason: reason,
                swapPolicy: swapPolicy
            )
        }
        let actual = sets.map { ActualSet(set: $0.id, load: $0.load, reps: $0.reps) }
        return ItemInput(
            itemId: id,
            mode: InputMode.perSetReps,
            sets: actual,
            performedExercise: performed,
            swapReason: reason,
            swapPolicy: swapPolicy
        )
    }
}

@MainActor
@Observable
final class LiveWorkout: Identifiable {
    let id = UUID()
    let repo: ActiveRepo
    let session: RenderedSession
    let startedAt: String
    var items: [LiveItem]

    init(repo: ActiveRepo, session: RenderedSession, restoring record: DayRecord? = nil) {
        self.repo = repo
        self.session = session
        self.startedAt = Self.startTimestamp(restoring: record)
        let units = repo.plan?.plan.units ?? .kg
        self.items = session.items.map { LiveItem(item: $0, units: units) }
        if let record { restore(record) }
    }

    /// The `startedAt` a resumed workout carries. A continued partial must finish
    /// on the *same date* it was saved under, because the log keys a record by
    /// (date, session): submitting on a different date would leave the partial
    /// orphaned instead of replacing it in place. Keep the saved time when it
    /// already falls on the record's date; otherwise pin to that date so the
    /// completion lands on the right row.
    private static func startTimestamp(restoring record: DayRecord?) -> String {
        guard let record else { return timestamp() }
        if let savedAt = record.savedAt, savedAt.hasPrefix(record.date) { return savedAt }
        return "\(record.date)T12:00:00Z"
    }

    private func restore(_ record: DayRecord) {
        var restoredItemIDs = Set<String>()
        for lift in record.lifts {
            guard let item = item(matching: lift, excluding: restoredItemIDs) else { continue }
            item.restore(from: lift)
            restoredItemIDs.insert(item.id)
        }
    }

    private func item(matching lift: LiftRecord, excluding restoredItemIDs: Set<String>) -> LiveItem? {
        if let itemID = lift.itemId,
           let exact = items.first(where: { $0.id == itemID }) {
            return exact
        }
        let exercise = Self.normalized(lift.exercise)
        return items.first {
            if restoredItemIDs.contains($0.id) { return false }
            if Self.normalized($0.item.exercise) == exercise { return true }
            return $0.item.exerciseOptions?.alternatives.contains {
                Self.normalized($0.exercise) == exercise
            } == true
        }
    }

    private static func normalized(_ exercise: String) -> String {
        LiveItem.normalized(exercise)
    }

    var requiredItems: [LiveItem] { items.filter(\.required) }
    var completedRequiredCount: Int { requiredItems.filter(\.isComplete).count }
    var allRequiredComplete: Bool { requiredItems.allSatisfy(\.isComplete) }
    var anyLogged: Bool { items.contains(where: \.anyLogged) }
    var canFinish: Bool { allRequiredComplete }
    var canSaveProgress: Bool { anyLogged && !allRequiredComplete }
    var canSubmit: Bool { anyLogged }
    var finishStatus: String {
        allRequiredComplete ? ExecutionStatus.complete : ExecutionStatus.partial
    }

    func finishInput(timestamp: String) -> ExecutionInput {
        executionInput(status: finishStatus, timestamp: timestamp)
    }

    func executionInput(status: String, timestamp: String) -> ExecutionInput {
        // An exercise the user never started is simply omitted (its equipment may have been busy,
        // or they chose to leave it out) — the same effect skipping used to have. A fully logged
        // exercise sends its real input; one only partially logged sends just the sets recorded.
        let isComplete = status == ExecutionStatus.complete
        let inputs: [ItemInput] = items.compactMap { item in
            if isComplete, item.isComplete { return item.itemInput() }
            if item.anyLogged { return item.partialInput() }
            return nil
        }
        return ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            status: status,
            startedAt: startedAt,
            completedAt: isComplete ? timestamp : nil,
            savedAt: isComplete ? nil : timestamp,
            inputs: inputs
        )
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

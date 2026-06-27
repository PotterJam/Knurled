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
    var rpe: Double?
    var logged: Bool
    var isExtra: Bool
    /// Warmups are guidance-only, so a user can advance past an early ramp set without
    /// recording it as performed. Bypassed warmups are ignored by the active cursor.
    var bypassed: Bool

    init(prescribed: PrescribedSet, defaultLoad: String?, isWarmup: Bool = false, isExtra: Bool = false) {
        self.id = prescribed.set
        self.prescribed = prescribed
        self.isWarmup = isWarmup
        self.reps = prescribed.targetReps
        self.load = defaultLoad ?? prescribed.load
        self.rpe = nil
        self.logged = false
        self.bypassed = false
        self.isExtra = isExtra
    }

    var isAdjusted: Bool {
        load != prescribed.load
    }

    var metrics: [String: String] {
        guard let rpe else { return [:] }
        return ["rpe": Self.formatRPE(rpe)]
    }

    var rpeText: String? {
        guard let rpe else { return nil }
        return Self.formatRPE(rpe)
    }

    static func formatRPE(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    static func parseRPE(_ value: String?) -> Double? {
        guard let value, let parsed = Double(value) else { return nil }
        return min(10, max(1, (parsed * 2).rounded() / 2))
    }
}

@MainActor
@Observable
final class LiveItem: Identifiable {
    let id: String
    let item: RenderedItem
    let units: Units
    let isTrackingOnlyExtra: Bool
    var warmups: [LiveSet]
    var sets: [LiveSet]
    var todayLoad: String?
    var performedExercise: String?
    var swapLabel: String?
    var swapPolicy: SwapPolicy?

    init(item: RenderedItem, units: Units, isTrackingOnlyExtra: Bool = false) {
        self.id = item.itemId
        self.item = item
        self.units = units
        self.isTrackingOnlyExtra = isTrackingOnlyExtra
        self.warmups = item.prescription.warmups.map { LiveSet(prescribed: $0, defaultLoad: $0.load, isWarmup: true) }
        self.sets = item.prescription.sets.map { LiveSet(prescribed: $0, defaultLoad: $0.load) }
    }

    var hasWarmups: Bool { !warmups.isEmpty }

    var mode: String { item.executionContract.recommendedInput }
    var phase: RenderedItemPhase { item.phase }
    var isSessionWarmup: Bool { phase == .warmup }
    var isSessionWarmdown: Bool { phase == .warmdown }
    var isAmrap: Bool { item.executionContract.recommendedInput == InputMode.amrapFinalSet }
    var required: Bool { item.executionContract.requiredForCompletion && !isTrackingOnlyExtra }
    var prescribedLoad: String? { item.prescription.sets.first?.load }
    var currentLoad: String? { todayLoad ?? sets.first?.load ?? prescribedLoad }
    var requiredSets: [LiveSet] { sets.filter { !$0.isExtra } }
    var lastRequiredSetID: Int? { requiredSets.last?.id }
    var isComplete: Bool { requiredSets.allSatisfy(\.logged) }
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

    func addSet() {
        let previous = sets.last
        let nextID = (sets.map(\.id).max() ?? 0) + 1
        let prescribed = PrescribedSet(
            set: nextID,
            load: previous?.load ?? currentLoad,
            targetReps: previous?.reps ?? previous?.prescribed.targetReps ?? 5,
            amrap: false,
            percentage: nil
        )
        sets.append(LiveSet(prescribed: prescribed, defaultLoad: prescribed.load, isExtra: true))
    }

    /// Only user-added (extra) sets can be removed; prescribed sets stay put.
    func removeSet(_ set: LiveSet) {
        guard set.isExtra else { return }
        sets.removeAll { $0 === set }
    }

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

        let restoredSetCount = max(lift.sets.count, lift.actual.map(\.set).max() ?? 0)
        while sets.count < restoredSetCount {
            addSet()
        }

        for (index, reps) in lift.sets.enumerated() where index < sets.count {
            sets[index].reps = reps
            sets[index].logged = true
        }

        if !lift.actual.isEmpty {
            let actual = lift.actual.sorted { $0.set < $1.set }
            for performed in actual {
                guard let set = sets.first(where: { $0.id == performed.set }) else { continue }
                set.reps = performed.reps
                set.load = performed.load
                set.rpe = LiveSet.parseRPE(performed.metrics["rpe"])
                set.logged = true
            }
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
            sets: sets.filter(\.logged).map { ActualSet(set: $0.id, load: $0.load, reps: $0.reps, metrics: $0.metrics) },
            performedExercise: performedExercise ?? (isTrackingOnlyExtra ? item.exercise : nil),
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
                finalSetReps: requiredSets.last?.reps ?? 0,
                sets: sets.filter { !$0.isExtra || $0.logged }.map { ActualSet(set: $0.id, load: $0.load, reps: $0.reps, metrics: $0.metrics) },
                load: overrideLoad,
                performedExercise: performed,
                swapReason: reason,
                swapPolicy: swapPolicy
            )
        }
        let actual = sets.filter { !$0.isExtra || $0.logged }.map { ActualSet(set: $0.id, load: $0.load, reps: $0.reps, metrics: $0.metrics) }
        return ItemInput(
            itemId: id,
            mode: InputMode.perSetReps,
            sets: actual,
            performedExercise: performed ?? (isTrackingOnlyExtra ? item.exercise : nil),
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

    init(repo: ActiveRepo, session: RenderedSession, restoring record: TrainingRecord? = nil) {
        self.repo = repo
        self.session = session
        self.startedAt = record?.startedAt ?? record?.savedAt ?? Self.timestamp()
        let units = repo.plan?.plan.units ?? .kg
        self.items = session.items.map { LiveItem(item: $0, units: units) }
        if let record { restore(record) }
    }

    private func restore(_ record: TrainingRecord) {
        var restoredItemIDs = Set<String>()
        for lift in record.lifts {
            guard let item = item(matching: lift, excluding: restoredItemIDs) ?? restoreExtra(from: lift) else { continue }
            item.restore(from: lift)
            restoredItemIDs.insert(item.id)
        }
    }

    private func restoreExtra(from lift: LiftRecord) -> LiveItem? {
        guard let itemID = lift.itemId, itemID.hasPrefix("extra.") else { return nil }
        let item = Self.extraItem(
            id: itemID,
            exercise: lift.exercise,
            load: lift.weight,
            sets: max(lift.sets.count, lift.actual.count, 1),
            reps: lift.sets.first ?? lift.actual.first?.reps ?? 5,
            units: repo.plan?.plan.units ?? .kg
        )
        if let warmdownIndex = items.firstIndex(where: { $0.isSessionWarmdown }) {
            items.insert(item, at: warmdownIndex)
        } else {
            items.append(item)
        }
        return item
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

    func moveItem(from sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = items.remove(at: sourceIndex)
        let adjustedTarget = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        items.insert(moved, at: adjustedTarget)
    }

    /// Remove an exercise the user added for this session. Prescribed plan exercises stay put.
    func removeItem(_ item: LiveItem) {
        guard item.isTrackingOnlyExtra else { return }
        items.removeAll { $0.id == item.id }
    }

    @discardableResult
    func addExtraExercise(exercise: String, load: String?, setCount: Int, reps: Int) -> LiveItem {
        let item = Self.extraItem(
            id: "extra.\(UUID().uuidString.lowercased())",
            exercise: LiveItem.normalized(exercise),
            load: load,
            sets: setCount,
            reps: reps,
            units: repo.plan?.plan.units ?? .kg
        )
        items.append(item)
        return item
    }

    private static func extraItem(
        id: String,
        exercise: String,
        load: String?,
        sets setCount: Int,
        reps: Int,
        units: Units
    ) -> LiveItem {
        let normalized = LiveItem.normalized(exercise)
        let safeSetCount = max(1, min(20, setCount))
        let safeReps = max(0, min(99, reps))
        let defaultLoad = load ?? LiveItem.defaultBaseLoad(for: normalized, units: units)
        let prescribedSets = (1...safeSetCount).map {
            PrescribedSet(set: $0, load: defaultLoad, targetReps: safeReps, amrap: false, percentage: nil)
        }
        let rendered = RenderedItem(
            itemId: id,
            slotId: id,
            progressionLane: "",
            progressionRule: "tracking_only",
            exercise: normalized,
            display: DisplayFields(title: LiveItem.titleCase(normalized), subtitle: "Extra work"),
            prescription: Prescription(sets: prescribedSets),
            executionContract: ExecutionContract(
                recommendedInput: InputMode.perSetReps,
                fallbackInputs: [],
                completionRule: "optional",
                eventTemplate: "tracking_only_v1",
                requiredForCompletion: false,
                inputSchema: InputSchema(mode: InputMode.perSetReps, fields: [], fallback: nil)
            ),
            effectPreview: EffectPreview(pass: [], fail: [], adjustedToday: []),
            rest: RestPrescription(seconds: 90, source: "extra", key: "extra"),
            identity: ItemIdentity(
                itemId: id,
                slotId: id,
                progressionLane: "",
                progressionRule: "tracking_only",
                planHash: "",
                renderedSessionHash: ""
            ),
            exerciseOptions: nil
        )
        return LiveItem(item: rendered, units: units, isTrackingOnlyExtra: true)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

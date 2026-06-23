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
    var reps: Int
    var load: String?
    var logged: Bool

    init(prescribed: PrescribedSet, defaultLoad: String?) {
        self.id = prescribed.set
        self.prescribed = prescribed
        self.reps = prescribed.targetReps
        self.load = defaultLoad ?? prescribed.load
        self.logged = false
    }

    var isAdjusted: Bool {
        guard let load, let prescribedLoad = prescribed.load else { return false }
        return load != prescribedLoad
    }
}

@MainActor
@Observable
final class LiveItem: Identifiable {
    let id: String
    let item: RenderedItem
    var sets: [LiveSet]
    var todayLoad: String?
    var performedExercise: String?
    var swapLabel: String?
    var swapPolicy: SwapPolicy?

    init(item: RenderedItem) {
        self.id = item.itemId
        self.item = item
        self.sets = item.prescription.sets.map { LiveSet(prescribed: $0, defaultLoad: $0.load) }
    }

    var mode: String { item.executionContract.recommendedInput }
    var isAmrap: Bool { item.executionContract.recommendedInput == InputMode.amrapFinalSet }
    var required: Bool { item.executionContract.requiredForCompletion }
    var prescribedLoad: String? { item.prescription.sets.first?.load }
    var isComplete: Bool { sets.allSatisfy(\.logged) }
    var anyLogged: Bool { sets.contains(where: \.logged) }
    var isAdjusted: Bool { sets.contains(where: \.isAdjusted) }
    var loggedCount: Int { sets.filter(\.logged).count }

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
    }

    func clearSwap() {
        performedExercise = nil
        swapLabel = nil
        swapPolicy = nil
    }

    static func titleCase(_ exercise: String) -> String {
        exercise.replacingOccurrences(of: "_", with: " ").capitalized
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

    /// A partial save records only the sets actually logged so far, as per-set reps, so an
    /// in-progress exercise (e.g. 2 of 3 sets) is not dropped (§16/§31).
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
    let continuesEventId: String?
    var items: [LiveItem]

    init(repo: ActiveRepo, session: RenderedSession, resuming saved: TrainingEvent? = nil) {
        self.repo = repo
        self.session = session
        self.startedAt = saved?.startedAt ?? Self.timestamp()
        self.continuesEventId = saved?.id
        self.items = session.items.map { LiveItem(item: $0) }
        if let saved { prefill(from: saved) }
    }

    /// Restores the sets already logged in a saved partial so the user continues exactly where
    /// they left off (§16/§19).
    private func prefill(from saved: TrainingEvent) {
        for result in saved.results {
            guard let item = items.first(where: { $0.id == result.slotId }) else { continue }
            if let performed = result.performedExercise, performed != item.item.exercise {
                item.performedExercise = performed
                item.swapPolicy = result.swapPolicy
            }
            for actual in result.actual {
                guard let set = item.sets.first(where: { $0.id == actual.set }) else { continue }
                set.reps = actual.reps
                if let load = actual.load { set.load = load }
                set.logged = true
            }
        }
    }

    var requiredItems: [LiveItem] { items.filter(\.required) }
    var completedRequiredCount: Int { requiredItems.filter(\.isComplete).count }
    var allRequiredComplete: Bool { requiredItems.allSatisfy(\.isComplete) }
    var anyLogged: Bool { items.contains(where: \.anyLogged) }

    func executionInput(status: String, timestamp: String) -> ExecutionInput {
        let isComplete = status == ExecutionStatus.complete
        let inputs = isComplete
            ? items.map { $0.itemInput() }
            : items.filter(\.anyLogged).map { $0.partialInput() }
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

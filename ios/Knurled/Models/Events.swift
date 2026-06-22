import Foundation

struct ReductionResult: Codable, Sendable, Hashable {
    var validation: ExecutionInputValidation
    var event: TrainingEvent?
    var effects: [Effect]
    var newState: StateProjection
    var nextWorkout: RenderedSession
}

struct TrainingEvent: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var type: String
    var schemaVersion: String?
    var program: String?
    var sessionId: String?
    var planHash: String?
    var templateHash: String?
    var renderedSessionHash: String?
    var engineVersion: String?
    var startedAt: String?
    var completedAt: String?
    var savedAt: String?
    var status: String?
    var results: [ExerciseResult]
    var resultsAdded: [ExerciseResult]
    var effects: [Effect]
    var continuesEventId: String?
    var correctsEventId: String?
    var reason: String?
    var policy: String?
    var lane: String?
    var change: StateChange?
    var cursor: CursorChange?
    var changes: [CorrectionChange]
}

struct ExerciseResult: Codable, Sendable, Hashable {
    var slotId: String
    var progressionLane: String?
    var progressionRule: String?
    var prescribedExercise: String?
    var performedExercise: String?
    var swapReason: String?
    var swapPolicy: SwapPolicy?
    var prescribed: JSONValue?
    var actual: [ActualSet]
    var outcome: String
    var effects: [Effect]
}

struct StateChange: Codable, Sendable, Hashable {
    var load: LoadChange?
    var stage: StageChange?
}

struct LoadChange: Codable, Sendable, Hashable {
    var from: String?
    var to: String
}

struct StageChange: Codable, Sendable, Hashable {
    var from: String?
    var to: String
}

struct CursorChange: Codable, Sendable, Hashable {
    var nextSession: String?
}

struct CorrectionChange: Codable, Sendable, Hashable {
    var path: String
    var before: JSONValue
    var after: JSONValue
}

struct BuildOutputs: Codable, Sendable {
    var state: StateProjection
    var ir: JSONValue
    var nextWorkout: RenderedSession?
    var validation: ValidationReport
}

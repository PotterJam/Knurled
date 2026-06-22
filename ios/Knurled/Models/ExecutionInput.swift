import Foundation

struct ExecutionInput: Codable, Sendable, Hashable {
    var type: String = "execution_input"
    var schemaVersion: String = "0.1"
    var renderedSessionHash: String
    var status: String
    var startedAt: String?
    var completedAt: String?
    var savedAt: String?
    var inputs: [ItemInput]
}

struct ItemInput: Codable, Sendable, Hashable {
    var itemId: String
    var mode: String
    var finalSetReps: Int?
    var sets: [ActualSet]
    var load: String?
    var performedExercise: String?
    var swapReason: String?
    var swapPolicy: SwapPolicy?

    init(
        itemId: String,
        mode: String,
        finalSetReps: Int? = nil,
        sets: [ActualSet] = [],
        load: String? = nil,
        performedExercise: String? = nil,
        swapReason: String? = nil,
        swapPolicy: SwapPolicy? = nil
    ) {
        self.itemId = itemId
        self.mode = mode
        self.finalSetReps = finalSetReps
        self.sets = sets
        self.load = load
        self.performedExercise = performedExercise
        self.swapReason = swapReason
        self.swapPolicy = swapPolicy
    }
}

struct ActualSet: Codable, Sendable, Hashable, Identifiable {
    var set: Int
    var load: String?
    var reps: Int

    var id: Int { self.set }
}

enum ExecutionStatus {
    static let complete = "complete"
    static let partial = "partial"
}

enum InputMode {
    static let amrapFinalSet = "amrap_final_set"
    static let perSetReps = "per_set_reps"
    static let loadOverride = "load_override"
    static let note = "note"
}

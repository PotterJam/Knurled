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
    var metrics: [String: String]

    var id: Int { self.set }

    enum CodingKeys: String, CodingKey {
        case set, load, reps, metrics
    }

    init(set: Int, load: String?, reps: Int, metrics: [String: String] = [:]) {
        self.set = set
        self.load = load
        self.reps = reps
        self.metrics = metrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        set = try container.decode(Int.self, forKey: .set)
        load = try container.decodeIfPresent(String.self, forKey: .load)
        reps = try container.decode(Int.self, forKey: .reps)
        metrics = try container.decodeIfPresent([String: String].self, forKey: .metrics) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(set, forKey: .set)
        try container.encodeIfPresent(load, forKey: .load)
        try container.encode(reps, forKey: .reps)
        if !metrics.isEmpty { try container.encode(metrics, forKey: .metrics) }
    }
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

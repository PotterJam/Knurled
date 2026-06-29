import Foundation

struct ReductionResult: Codable, Sendable, Hashable {
    var validation: ExecutionInputValidation
    var results: [ExerciseResult]
    var effects: [Effect]
    var newState: StateProjection
    var nextWorkout: RenderedSession
}

struct SubmitOutcome: Codable, Sendable, Hashable {
    var validation: ExecutionInputValidation
    var record: TrainingRecord
    var newState: StateProjection
    var effects: [Effect]
    var changedFiles: [String]
}

enum SubmitMode: String, Codable, Sendable, Hashable, CaseIterable {
    case advance
    case offDay = "off_day"
    case reset

    var title: String {
        switch self {
        case .advance: "Advance"
        case .offDay: "Off-day"
        case .reset: "Reset"
        }
    }

    var subtitle: String {
        switch self {
        case .advance: "Apply the program progression rules."
        case .offDay: "Record the workout but leave loads and stages unchanged."
        case .reset: "Use today's performed loads as the new baseline."
        }
    }

    var commitVerb: String {
        switch self {
        case .advance: "Complete"
        case .offDay: "Record off-day"
        case .reset: "Reset"
        }
    }
}

enum RecordKind: String, Codable, Sendable, Hashable {
    case workout
    case programMarker = "program_marker"
}

struct TrainingRecord: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var revision: Int
    var kind: RecordKind
    var date: String
    var sessionId: String?
    var startedAt: String?
    var completedAt: String?
    var updatedAt: String?
    var program: String?
    var note: String?
    var lifts: [LiftRecord]

    enum CodingKeys: String, CodingKey {
        case id, revision, kind, date, sessionId, startedAt, completedAt
        case updatedAt, program, note, lifts
    }

    init(
        id: String,
        revision: Int = 1,
        kind: RecordKind = .workout,
        date: String,
        sessionId: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        updatedAt: String? = nil,
        program: String? = nil,
        note: String? = nil,
        lifts: [LiftRecord] = []
    ) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.date = date
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.updatedAt = updatedAt
        self.program = program
        self.note = note
        self.lifts = lifts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        revision = try container.decode(Int.self, forKey: .revision)
        kind = try container.decode(RecordKind.self, forKey: .kind)
        date = try container.decode(String.self, forKey: .date)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        program = try container.decodeIfPresent(String.self, forKey: .program)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        lifts = try container.decodeIfPresent([LiftRecord].self, forKey: .lifts) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(revision, forKey: .revision)
        try container.encode(kind, forKey: .kind)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encodeIfPresent(note, forKey: .note)
        if !lifts.isEmpty { try container.encode(lifts, forKey: .lifts) }
    }

}

struct LiftRecord: Codable, Sendable, Hashable, Identifiable {
    var liftId: String
    var itemId: String?
    var exercise: String
    var weight: String?
    var sets: [Int]
    var actual: [ActualSet]
    var metrics: [String: String]
    var note: String?

    var id: String { liftId }

    enum CodingKeys: String, CodingKey {
        case liftId, itemId, exercise, weight, sets, actual, metrics, note
    }

    init(
        liftId: String,
        itemId: String? = nil,
        exercise: String,
        weight: String? = nil,
        sets: [Int] = [],
        actual: [ActualSet] = [],
        metrics: [String: String] = [:],
        note: String? = nil
    ) {
        self.liftId = liftId
        self.itemId = itemId
        self.exercise = exercise
        self.weight = weight
        self.sets = sets
        self.actual = actual
        self.metrics = metrics
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liftId = try container.decode(String.self, forKey: .liftId)
        itemId = try container.decodeIfPresent(String.self, forKey: .itemId)
        exercise = try container.decode(String.self, forKey: .exercise)
        weight = try container.decodeIfPresent(String.self, forKey: .weight)
        sets = try container.decodeIfPresent([Int].self, forKey: .sets) ?? []
        actual = try container.decodeIfPresent([ActualSet].self, forKey: .actual) ?? []
        metrics = try container.decodeIfPresent([String: String].self, forKey: .metrics) ?? [:]
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(liftId, forKey: .liftId)
        try container.encodeIfPresent(itemId, forKey: .itemId)
        try container.encode(exercise, forKey: .exercise)
        try container.encodeIfPresent(weight, forKey: .weight)
        if !sets.isEmpty { try container.encode(sets, forKey: .sets) }
        if !actual.isEmpty { try container.encode(actual, forKey: .actual) }
        if !metrics.isEmpty { try container.encode(metrics, forKey: .metrics) }
        try container.encodeIfPresent(note, forKey: .note)
    }
}

struct AmendRecordRequest: Encodable, Sendable {
    var recordId: String
    var expectedRevision: Int
    var updatedAt: String
    var amendment: RecordAmendment

    func encode(to encoder: Encoder) throws {
        try amendment.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordId, forKey: .recordId)
        try container.encode(expectedRevision, forKey: .expectedRevision)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey { case recordId, expectedRevision, updatedAt }
}

enum RecordAmendment: Encodable, Sendable {
    case addSet(liftId: String, load: String?, reps: Int, metrics: [String: String])
    case addExercise(exercise: String, weight: String?, note: String?, sets: [ActualSet])
    case replaceLifts([LiftRecord])

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addSet(let liftId, let load, let reps, let metrics):
            try container.encode("add_set", forKey: .op)
            try container.encode(liftId, forKey: .liftId)
            try container.encodeIfPresent(load, forKey: .load)
            try container.encode(reps, forKey: .reps)
            try container.encode(metrics, forKey: .metrics)
        case .addExercise(let exercise, let weight, let note, let sets):
            try container.encode("add_exercise", forKey: .op)
            try container.encode(exercise, forKey: .exercise)
            try container.encodeIfPresent(weight, forKey: .weight)
            try container.encodeIfPresent(note, forKey: .note)
            try container.encode(sets, forKey: .sets)
        case .replaceLifts(let lifts):
            try container.encode("replace_lifts", forKey: .op)
            try container.encode(lifts, forKey: .lifts)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op, liftId, load, reps, metrics, exercise, weight, note, sets, lifts
    }
}

struct AmendRecordOutcome: Codable, Sendable, Hashable {
    var record: TrainingRecord
    var changedFiles: [String]
    var recomputedLanes: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        record = try container.decode(TrainingRecord.self, forKey: .record)
        changedFiles = try container.decode([String].self, forKey: .changedFiles)
        recomputedLanes = try container.decodeIfPresent([String].self, forKey: .recomputedLanes) ?? []
    }
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

    enum CodingKeys: String, CodingKey {
        case slotId, progressionLane, progressionRule, prescribedExercise, performedExercise
        case swapReason, swapPolicy, prescribed, actual, outcome, effects
    }

    init(
        slotId: String,
        progressionLane: String? = nil,
        progressionRule: String? = nil,
        prescribedExercise: String? = nil,
        performedExercise: String? = nil,
        swapReason: String? = nil,
        swapPolicy: SwapPolicy? = nil,
        prescribed: JSONValue? = nil,
        actual: [ActualSet] = [],
        outcome: String,
        effects: [Effect] = []
    ) {
        self.slotId = slotId
        self.progressionLane = progressionLane
        self.progressionRule = progressionRule
        self.prescribedExercise = prescribedExercise
        self.performedExercise = performedExercise
        self.swapReason = swapReason
        self.swapPolicy = swapPolicy
        self.prescribed = prescribed
        self.actual = actual
        self.outcome = outcome
        self.effects = effects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slotId = try container.decode(String.self, forKey: .slotId)
        progressionLane = try container.decodeIfPresent(String.self, forKey: .progressionLane)
        progressionRule = try container.decodeIfPresent(String.self, forKey: .progressionRule)
        prescribedExercise = try container.decodeIfPresent(String.self, forKey: .prescribedExercise)
        performedExercise = try container.decodeIfPresent(String.self, forKey: .performedExercise)
        swapReason = try container.decodeIfPresent(String.self, forKey: .swapReason)
        swapPolicy = try container.decodeIfPresent(SwapPolicy.self, forKey: .swapPolicy)
        prescribed = try container.decodeIfPresent(JSONValue.self, forKey: .prescribed)
        actual = try container.decodeIfPresent([ActualSet].self, forKey: .actual) ?? []
        outcome = try container.decode(String.self, forKey: .outcome)
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
    }
}

struct BuildOutputs: Codable, Sendable {
    var state: StateProjection
    var ir: JSONValue
    var nextWorkout: RenderedSession?
    var validation: ValidationReport
}

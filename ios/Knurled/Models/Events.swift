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
    var recordDay: DayRecord
    var newState: StateProjection
    var effects: [Effect]
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

struct DayRecord: Codable, Sendable, Hashable, Identifiable {
    var date: String
    var status: String?
    var sessionId: String?
    var savedAt: String?
    var completedAt: String?
    var program: String?
    var note: String?
    var lifts: [LiftRecord]

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, status, sessionId, savedAt, completedAt, program, note, lifts
    }

    init(
        date: String,
        status: String? = nil,
        sessionId: String? = nil,
        savedAt: String? = nil,
        completedAt: String? = nil,
        program: String? = nil,
        note: String? = nil,
        lifts: [LiftRecord] = []
    ) {
        self.date = date
        self.status = status
        self.sessionId = sessionId
        self.savedAt = savedAt
        self.completedAt = completedAt
        self.program = program
        self.note = note
        self.lifts = lifts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        program = try container.decodeIfPresent(String.self, forKey: .program)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        lifts = try container.decodeIfPresent([LiftRecord].self, forKey: .lifts) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encodeIfPresent(note, forKey: .note)
        if !lifts.isEmpty { try container.encode(lifts, forKey: .lifts) }
    }
}

struct LiftRecord: Codable, Sendable, Hashable, Identifiable {
    var itemId: String?
    var exercise: String
    var weight: String?
    var sets: [Int]
    var actual: [ActualSet]
    var metrics: [String: String]
    var note: String?

    var id: String {
        [exercise, weight, sets.map(String.init).joined(separator: "-")]
            .compactMap { $0 }
            .joined(separator: "#")
    }

    enum CodingKeys: String, CodingKey {
        case itemId, exercise, weight, sets, actual, metrics, note
    }

    init(
        itemId: String? = nil,
        exercise: String,
        weight: String? = nil,
        sets: [Int] = [],
        actual: [ActualSet] = [],
        metrics: [String: String] = [:],
        note: String? = nil
    ) {
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
        try container.encodeIfPresent(itemId, forKey: .itemId)
        try container.encode(exercise, forKey: .exercise)
        try container.encodeIfPresent(weight, forKey: .weight)
        if !sets.isEmpty { try container.encode(sets, forKey: .sets) }
        if !actual.isEmpty { try container.encode(actual, forKey: .actual) }
        if !metrics.isEmpty { try container.encode(metrics, forKey: .metrics) }
        try container.encodeIfPresent(note, forKey: .note)
    }
}

struct LogMonth: Codable, Sendable, Hashable {
    var month: String
    var days: [DayRecord]

    init(month: String, days: [DayRecord] = []) {
        self.month = month
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decode(String.self, forKey: .month)
        days = try container.decodeIfPresent([DayRecord].self, forKey: .days) ?? []
    }

    mutating func upsert(day: DayRecord) {
        if let index = days.firstIndex(where: { $0.date == day.date }) {
            days[index] = day
        } else {
            days.append(day)
        }
        days.sort { $0.date < $1.date }
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

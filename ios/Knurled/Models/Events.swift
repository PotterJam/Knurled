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

    var workoutResults: [ExerciseResult] { results + resultsAdded }

    enum CodingKeys: String, CodingKey {
        case id, type, schemaVersion, program, sessionId, planHash, templateHash
        case renderedSessionHash, engineVersion, startedAt, completedAt, savedAt, status
        case results, resultsAdded, effects, continuesEventId, correctsEventId
        case reason, policy, lane, change, cursor, changes
    }

    init(
        id: String,
        type: String,
        schemaVersion: String?,
        program: String?,
        sessionId: String?,
        planHash: String?,
        templateHash: String?,
        renderedSessionHash: String?,
        engineVersion: String?,
        startedAt: String?,
        completedAt: String?,
        savedAt: String?,
        status: String?,
        results: [ExerciseResult],
        resultsAdded: [ExerciseResult],
        effects: [Effect],
        continuesEventId: String?,
        correctsEventId: String?,
        reason: String?,
        policy: String?,
        lane: String?,
        change: StateChange?,
        cursor: CursorChange?,
        changes: [CorrectionChange]
    ) {
        self.id = id
        self.type = type
        self.schemaVersion = schemaVersion
        self.program = program
        self.sessionId = sessionId
        self.planHash = planHash
        self.templateHash = templateHash
        self.renderedSessionHash = renderedSessionHash
        self.engineVersion = engineVersion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.savedAt = savedAt
        self.status = status
        self.results = results
        self.resultsAdded = resultsAdded
        self.effects = effects
        self.continuesEventId = continuesEventId
        self.correctsEventId = correctsEventId
        self.reason = reason
        self.policy = policy
        self.lane = lane
        self.change = change
        self.cursor = cursor
        self.changes = changes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion)
        program = try container.decodeIfPresent(String.self, forKey: .program)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        planHash = try container.decodeIfPresent(String.self, forKey: .planHash)
        templateHash = try container.decodeIfPresent(String.self, forKey: .templateHash)
        renderedSessionHash = try container.decodeIfPresent(String.self, forKey: .renderedSessionHash)
        engineVersion = try container.decodeIfPresent(String.self, forKey: .engineVersion)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        results = try container.decodeIfPresent([ExerciseResult].self, forKey: .results) ?? []
        resultsAdded = try container.decodeIfPresent([ExerciseResult].self, forKey: .resultsAdded) ?? []
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        continuesEventId = try container.decodeIfPresent(String.self, forKey: .continuesEventId)
        correctsEventId = try container.decodeIfPresent(String.self, forKey: .correctsEventId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        policy = try container.decodeIfPresent(String.self, forKey: .policy)
        lane = try container.decodeIfPresent(String.self, forKey: .lane)
        change = try container.decodeIfPresent(StateChange.self, forKey: .change)
        cursor = try container.decodeIfPresent(CursorChange.self, forKey: .cursor)
        changes = try container.decodeIfPresent([CorrectionChange].self, forKey: .changes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(program, forKey: .program)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(planHash, forKey: .planHash)
        try container.encodeIfPresent(templateHash, forKey: .templateHash)
        try container.encodeIfPresent(renderedSessionHash, forKey: .renderedSessionHash)
        try container.encodeIfPresent(engineVersion, forKey: .engineVersion)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(savedAt, forKey: .savedAt)
        try container.encodeIfPresent(status, forKey: .status)
        if !results.isEmpty { try container.encode(results, forKey: .results) }
        if !resultsAdded.isEmpty { try container.encode(resultsAdded, forKey: .resultsAdded) }
        if !effects.isEmpty { try container.encode(effects, forKey: .effects) }
        try container.encodeIfPresent(continuesEventId, forKey: .continuesEventId)
        try container.encodeIfPresent(correctsEventId, forKey: .correctsEventId)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(policy, forKey: .policy)
        try container.encodeIfPresent(lane, forKey: .lane)
        try container.encodeIfPresent(change, forKey: .change)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        if !changes.isEmpty { try container.encode(changes, forKey: .changes) }
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
        progressionLane: String?,
        progressionRule: String?,
        prescribedExercise: String?,
        performedExercise: String?,
        swapReason: String?,
        swapPolicy: SwapPolicy?,
        prescribed: JSONValue?,
        actual: [ActualSet],
        outcome: String,
        effects: [Effect]
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slotId, forKey: .slotId)
        try container.encodeIfPresent(progressionLane, forKey: .progressionLane)
        try container.encodeIfPresent(progressionRule, forKey: .progressionRule)
        try container.encodeIfPresent(prescribedExercise, forKey: .prescribedExercise)
        try container.encodeIfPresent(performedExercise, forKey: .performedExercise)
        try container.encodeIfPresent(swapReason, forKey: .swapReason)
        try container.encodeIfPresent(swapPolicy, forKey: .swapPolicy)
        try container.encodeIfPresent(prescribed, forKey: .prescribed)
        if !actual.isEmpty { try container.encode(actual, forKey: .actual) }
        try container.encode(outcome, forKey: .outcome)
        if !effects.isEmpty { try container.encode(effects, forKey: .effects) }
    }
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
    /// Saved partials re-rendered against the current state so they stay resumable from history
    /// after a partial save advances the cursor past them (§16/§19).
    var resumableSessions: [RenderedSession]?
    var validation: ValidationReport
}

import Foundation

/// Editable, structured mirror of the engine's `DslTemplate` (see
/// `engine/src/model.rs`). This is the single model the in-app authoring editor
/// mutates; it is round-tripped through `knurled_render_template` /
/// `knurled_parse_template` / `knurled_preview_template` so the engine remains
/// the sole producer and validator of `.fitspec` text (Phase 6 / ADR 0003).
///
/// Coding note: the shared `KnurledCoding` coders use snake_case key conversion,
/// so all `CodingKeys` here are camelCase. The tagged enums (`DslInitial`,
/// `DslTrigger`, `DslEffect`) carry a `kind`/`op` discriminator and need manual
/// `Codable`; the plain string enums decode straight from their snake_case
/// values.
struct DslTemplate: Codable, Sendable, Hashable {
    var name: String
    var version: String
    var rotation: [String]
    var restSeconds: Int
    var warmup: WarmupScheme?
    var sessionDisplayNames: [String: String]
    var sessions: [String: [DslSessionItem]]
    var lanes: [String: DslLane]

    init(
        name: String,
        version: String = "1.0.0",
        rotation: [String] = [],
        restSeconds: Int = 120,
        warmup: WarmupScheme? = nil,
        sessionDisplayNames: [String: String] = [:],
        sessions: [String: [DslSessionItem]] = [:],
        lanes: [String: DslLane] = [:]
    ) {
        self.name = name
        self.version = version
        self.rotation = rotation
        self.restSeconds = restSeconds
        self.warmup = warmup
        self.sessionDisplayNames = sessionDisplayNames
        self.sessions = sessions
        self.lanes = lanes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        rotation = try container.decodeIfPresent([String].self, forKey: .rotation) ?? []
        restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 120
        warmup = try container.decodeIfPresent(WarmupScheme.self, forKey: .warmup)
        sessionDisplayNames =
            try container.decodeIfPresent([String: String].self, forKey: .sessionDisplayNames) ?? [:]
        sessions = try container.decode([String: [DslSessionItem]].self, forKey: .sessions)
        lanes = try container.decode([String: DslLane].self, forKey: .lanes)
    }
}

struct DslSessionItem: Codable, Sendable, Hashable {
    var lane: String
    var slotId: String
    var accessoryKey: String?
    var defaultExercise: String?

    init(lane: String, slotId: String, accessoryKey: String? = nil, defaultExercise: String? = nil) {
        self.lane = lane
        self.slotId = slotId
        self.accessoryKey = accessoryKey
        self.defaultExercise = defaultExercise
    }
}

struct DslLane: Codable, Sendable, Hashable {
    var exercise: String
    var tier: String?
    var basis: DslBasis
    var initial: DslInitial
    var sequence: DslSequence
    var stages: [DslStage]
    var rules: [DslRule]
    var restSeconds: Int?
    var warmup: WarmupScheme?

    init(
        exercise: String,
        tier: String? = nil,
        basis: DslBasis = .workingWeight,
        initial: DslInitial = .basis,
        sequence: DslSequence = .none,
        stages: [DslStage] = [],
        rules: [DslRule] = [],
        restSeconds: Int? = nil,
        warmup: WarmupScheme? = nil
    ) {
        self.exercise = exercise
        self.tier = tier
        self.basis = basis
        self.initial = initial
        self.sequence = sequence
        self.stages = stages
        self.rules = rules
        self.restSeconds = restSeconds
        self.warmup = warmup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exercise = try container.decode(String.self, forKey: .exercise)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        basis = try container.decodeIfPresent(DslBasis.self, forKey: .basis) ?? .workingWeight
        initial = try container.decodeIfPresent(DslInitial.self, forKey: .initial) ?? .basis
        sequence = try container.decodeIfPresent(DslSequence.self, forKey: .sequence) ?? .none
        stages = try container.decodeIfPresent([DslStage].self, forKey: .stages) ?? []
        rules = try container.decodeIfPresent([DslRule].self, forKey: .rules) ?? []
        restSeconds = try container.decodeIfPresent(Int.self, forKey: .restSeconds)
        warmup = try container.decodeIfPresent(WarmupScheme.self, forKey: .warmup)
    }
}

enum DslBasis: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case workingWeight = "working_weight"
    case trainingMax = "training_max"
    case bodyweight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .workingWeight: return "Working weight"
        case .trainingMax: return "Training max"
        case .bodyweight: return "Bodyweight"
        }
    }
}

enum DslSequence: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case none
    case stages
    case cycle
    case waves
    case rotation

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Internally-tagged (`kind`) mirror of the engine's `DslInitial`.
enum DslInitial: Codable, Sendable, Hashable {
    case basis
    case percent(Int)
    case performed

    private enum CodingKeys: String, CodingKey {
        case kind
        case percentage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "basis": self = .basis
        case "performed": self = .performed
        case "percent": self = .percent(try container.decode(Int.self, forKey: .percentage))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown initial kind: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .basis: try container.encode("basis", forKey: .kind)
        case .performed: try container.encode("performed", forKey: .kind)
        case .percent(let percentage):
            try container.encode("percent", forKey: .kind)
            try container.encode(percentage, forKey: .percentage)
        }
    }
}

struct DslStage: Codable, Sendable, Hashable {
    var id: String
    var groups: [DslSetGroup]

    init(id: String, groups: [DslSetGroup]) {
        self.id = id
        self.groups = groups
    }
}

struct DslSetGroup: Codable, Sendable, Hashable {
    var count: Int
    var reps: Int
    var intensity: Int
    var amrap: Bool
    var repMin: Int?
    var repMax: Int?
    var rpe: Int?

    init(
        count: Int = 3,
        reps: Int = 5,
        intensity: Int = 100,
        amrap: Bool = false,
        repMin: Int? = nil,
        repMax: Int? = nil,
        rpe: Int? = nil
    ) {
        self.count = count
        self.reps = reps
        self.intensity = intensity
        self.amrap = amrap
        self.repMin = repMin
        self.repMax = repMax
        self.rpe = rpe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
        reps = try container.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        intensity = try container.decodeIfPresent(Int.self, forKey: .intensity) ?? 100
        amrap = try container.decodeIfPresent(Bool.self, forKey: .amrap) ?? false
        repMin = try container.decodeIfPresent(Int.self, forKey: .repMin)
        repMax = try container.decodeIfPresent(Int.self, forKey: .repMax)
        rpe = try container.decodeIfPresent(Int.self, forKey: .rpe)
    }
}

struct DslRule: Codable, Sendable, Hashable {
    var trigger: DslTrigger
    var stage: String?
    var effects: [DslEffect]

    init(trigger: DslTrigger, stage: String? = nil, effects: [DslEffect]) {
        self.trigger = trigger
        self.stage = stage
        self.effects = effects
    }
}

/// Internally-tagged (`kind`) mirror of the engine's `DslTrigger`.
enum DslTrigger: Codable, Sendable, Hashable {
    case pass
    case fail
    case amrapGte(reps: Int)
    case stall(count: Int)
    case cycleEnd
    case rangeTop

    private enum CodingKeys: String, CodingKey {
        case kind
        case reps
        case count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "pass": self = .pass
        case "fail": self = .fail
        case "amrap_gte": self = .amrapGte(reps: try container.decode(Int.self, forKey: .reps))
        case "stall": self = .stall(count: try container.decode(Int.self, forKey: .count))
        case "cycle_end": self = .cycleEnd
        case "range_top": self = .rangeTop
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown trigger kind: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pass: try container.encode("pass", forKey: .kind)
        case .fail: try container.encode("fail", forKey: .kind)
        case .amrapGte(let reps):
            try container.encode("amrap_gte", forKey: .kind)
            try container.encode(reps, forKey: .reps)
        case .stall(let count):
            try container.encode("stall", forKey: .kind)
            try container.encode(count, forKey: .count)
        case .cycleEnd: try container.encode("cycle_end", forKey: .kind)
        case .rangeTop: try container.encode("range_top", forKey: .kind)
        }
    }
}

/// Internally-tagged (`op`) mirror of the engine's `DslEffect`. `increaseLoad`
/// and `recomputeTm` carry a free-form amount string (e.g. `"2.5"` or `"5%"`);
/// `increaseReps` carries an integer.
enum DslEffect: Codable, Sendable, Hashable {
    case increaseLoad(amount: String)
    case deload(percent: Int)
    case resetLoad(percent: Int)
    case advanceStage
    case resetStage
    case increaseReps(amount: Int)
    case resetReps
    case recomputeTm(amount: String)
    case advanceCycle

    private enum CodingKeys: String, CodingKey {
        case op
        case amount
        case percent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .op) {
        case "increase_load": self = .increaseLoad(amount: try container.decode(String.self, forKey: .amount))
        case "deload": self = .deload(percent: try container.decode(Int.self, forKey: .percent))
        case "reset_load": self = .resetLoad(percent: try container.decode(Int.self, forKey: .percent))
        case "advance_stage": self = .advanceStage
        case "reset_stage": self = .resetStage
        case "increase_reps": self = .increaseReps(amount: try container.decode(Int.self, forKey: .amount))
        case "reset_reps": self = .resetReps
        case "recompute_tm": self = .recomputeTm(amount: try container.decode(String.self, forKey: .amount))
        case "advance_cycle": self = .advanceCycle
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container, debugDescription: "unknown effect op: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .increaseLoad(let amount):
            try container.encode("increase_load", forKey: .op)
            try container.encode(amount, forKey: .amount)
        case .deload(let percent):
            try container.encode("deload", forKey: .op)
            try container.encode(percent, forKey: .percent)
        case .resetLoad(let percent):
            try container.encode("reset_load", forKey: .op)
            try container.encode(percent, forKey: .percent)
        case .advanceStage: try container.encode("advance_stage", forKey: .op)
        case .resetStage: try container.encode("reset_stage", forKey: .op)
        case .increaseReps(let amount):
            try container.encode("increase_reps", forKey: .op)
            try container.encode(amount, forKey: .amount)
        case .resetReps: try container.encode("reset_reps", forKey: .op)
        case .recomputeTm(let amount):
            try container.encode("recompute_tm", forKey: .op)
            try container.encode(amount, forKey: .amount)
        case .advanceCycle: try container.encode("advance_cycle", forKey: .op)
        }
    }
}

// MARK: - Warmup

struct WarmupScheme: Codable, Sendable, Hashable {
    var emptyBarSets: Int
    var emptyBarReps: Int
    var ramp: [WarmupStep]
    var basis: WarmupBasis

    init(emptyBarSets: Int = 0, emptyBarReps: Int = 0, ramp: [WarmupStep] = [], basis: WarmupBasis = .topSet) {
        self.emptyBarSets = emptyBarSets
        self.emptyBarReps = emptyBarReps
        self.ramp = ramp
        self.basis = basis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emptyBarSets = try container.decodeIfPresent(Int.self, forKey: .emptyBarSets) ?? 0
        emptyBarReps = try container.decodeIfPresent(Int.self, forKey: .emptyBarReps) ?? 0
        ramp = try container.decodeIfPresent([WarmupStep].self, forKey: .ramp) ?? []
        basis = try container.decodeIfPresent(WarmupBasis.self, forKey: .basis) ?? .topSet
    }
}

struct WarmupStep: Codable, Sendable, Hashable {
    var percentage: Int
    var reps: Int
}

enum WarmupBasis: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case topSet = "top_set"
    case workingWeight = "working_weight"
    case trainingMax = "training_max"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .topSet: return "Top set"
        case .workingWeight: return "Working weight"
        case .trainingMax: return "Training max"
        }
    }
}

// MARK: - Preview FFI contract

/// Request posted to `knurled_preview_template` on every edit: the candidate
/// template plus the plan-level numbers needed to render a first workout.
struct PreviewTemplateRequest: Encodable, Sendable {
    var dsl: DslTemplate?
    var text: String?
    var units: Units
    var initialNumbers: [String: String]
    var suggestedDays: [String]
    var rest: RestPolicy?

    init(
        dsl: DslTemplate? = nil,
        text: String? = nil,
        units: Units = .kg,
        initialNumbers: [String: String] = [:],
        suggestedDays: [String] = [],
        rest: RestPolicy? = nil
    ) {
        self.dsl = dsl
        self.text = text
        self.units = units
        self.initialNumbers = initialNumbers
        self.suggestedDays = suggestedDays
        self.rest = rest
    }
}

struct TemplatePreview: Decodable, Sendable {
    var validation: ValidationReport
    var preview: RenderedSession?
}

/// `knurled_render_template` envelope payload: `{ "text": "..." }`.
struct RenderedTemplateText: Decodable, Sendable {
    var text: String
}

/// `knurled_parse_template` envelope payload: `{ "dsl": DslTemplate }`.
struct ParsedTemplate: Decodable, Sendable {
    var dsl: DslTemplate
}


import Foundation

struct PlanEditOutcome: Codable, Sendable {
    var applied: Bool
    var changedFiles: [String]
    var outputs: BuildOutputs
}

enum PlanEdit: Encodable, Sendable {
    case quick(QuickPlanEdit)
    case savePatch(PatchPlanEdit)
    case deletePatch(filename: String)
    case switchProgram(SwitchProgramEdit)

    private enum CodingKeys: String, CodingKey {
        case kind
        case suggestedDays
        case equipment
        case customExercise
        case accessory
        case sessionExercises
        case rest
        case filename
        case name
        case description
        case activeFrom
        case expires
        case operations
        case template
        case planName
        case units
        case initialNumbers
        case date
        case note
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quick(let edit):
            try container.encode("quick", forKey: .kind)
            try container.encodeIfPresent(edit.suggestedDays, forKey: .suggestedDays)
            try container.encodeIfPresent(edit.equipment, forKey: .equipment)
            try container.encodeIfPresent(edit.customExercise, forKey: .customExercise)
            try container.encodeIfPresent(edit.accessory, forKey: .accessory)
            try container.encodeIfPresent(edit.sessionExercises, forKey: .sessionExercises)
            try container.encodeIfPresent(edit.rest, forKey: .rest)
        case .savePatch(let edit):
            try container.encode("save_patch", forKey: .kind)
            try container.encodeIfPresent(edit.filename, forKey: .filename)
            try container.encode(edit.name, forKey: .name)
            try container.encode(edit.description, forKey: .description)
            try container.encodeIfPresent(edit.activeFrom, forKey: .activeFrom)
            try container.encodeIfPresent(edit.expires, forKey: .expires)
            try container.encode(edit.operations, forKey: .operations)
        case .deletePatch(let filename):
            try container.encode("delete_patch", forKey: .kind)
            try container.encode(filename, forKey: .filename)
        case .switchProgram(let edit):
            try container.encode("switch_program", forKey: .kind)
            try container.encode(edit.template, forKey: .template)
            try container.encodeIfPresent(edit.planName, forKey: .planName)
            try container.encode(edit.units, forKey: .units)
            try container.encode(edit.initialNumbers, forKey: .initialNumbers)
            try container.encodeIfPresent(edit.suggestedDays, forKey: .suggestedDays)
            try container.encode(edit.date, forKey: .date)
            try container.encodeIfPresent(edit.note, forKey: .note)
        }
    }
}

struct QuickPlanEdit: Encodable, Sendable {
    var suggestedDays: [String]?
    var equipment: EquipmentProfile?
    var customExercise: CustomExerciseEdit?
    var accessory: AccessoryEdit?
    var sessionExercises: SessionExercisePolicy?
    var rest: RestPolicy?
}

struct RestPolicy: Codable, Sendable, Hashable {
    var defaultSeconds: Int?
    var byTier: [String: Int]
    var bySlot: [String: Int]
    var byLane: [String: Int]
    var byExercise: [String: Int]

    init(
        defaultSeconds: Int? = nil,
        byTier: [String: Int] = [:],
        bySlot: [String: Int] = [:],
        byLane: [String: Int] = [:],
        byExercise: [String: Int] = [:]
    ) {
        self.defaultSeconds = defaultSeconds
        self.byTier = byTier
        self.bySlot = bySlot
        self.byLane = byLane
        self.byExercise = byExercise
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSeconds = try container.decodeIfPresent(Int.self, forKey: .defaultSeconds)
        byTier = try container.decodeIfPresent([String: Int].self, forKey: .byTier) ?? [:]
        bySlot = try container.decodeIfPresent([String: Int].self, forKey: .bySlot) ?? [:]
        byLane = try container.decodeIfPresent([String: Int].self, forKey: .byLane) ?? [:]
        byExercise = try container.decodeIfPresent([String: Int].self, forKey: .byExercise) ?? [:]
    }
}

struct SessionExercisePolicy: Codable, Sendable, Hashable {
    var warmup: [SessionExercise]
    var warmdown: [SessionExercise]

    init(warmup: [SessionExercise] = [], warmdown: [SessionExercise] = []) {
        self.warmup = warmup
        self.warmdown = warmdown
    }

    private enum CodingKeys: String, CodingKey {
        case warmup
        case warmdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        warmup = try container.decodeIfPresent([SessionExercise].self, forKey: .warmup) ?? []
        warmdown = try container.decodeIfPresent([SessionExercise].self, forKey: .warmdown) ?? []
    }
}

struct SessionExercise: Codable, Sendable, Hashable, Identifiable {
    var exercise: String
    var label: String?
    var sets: Int
    var reps: Int
    var load: String?
    var note: String?

    var id: String { "\(exercise)-\(sets)-\(reps)-\(load ?? "")-\(note ?? "")" }

    init(
        exercise: String,
        label: String? = nil,
        sets: Int = 1,
        reps: Int = 0,
        load: String? = nil,
        note: String? = nil
    ) {
        self.exercise = exercise
        self.label = label
        self.sets = sets
        self.reps = reps
        self.load = load
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case exercise
        case label
        case sets
        case reps
        case load
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exercise = try container.decode(String.self, forKey: .exercise)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        sets = try container.decodeIfPresent(Int.self, forKey: .sets) ?? 1
        reps = try container.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        load = try container.decodeIfPresent(String.self, forKey: .load)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

struct CustomExerciseEdit: Encodable, Sendable {
    var id: String
    var label: String
    var pattern: String?
    var implement: String?
}

struct AccessoryEdit: Encodable, Sendable {
    var slot: String
    var exercise: String
}

struct EquipmentProfile: Codable, Sendable, Hashable {
    var bars: [String: Double]
    var platePairs: [Double]
    var dumbbells: [Double]
    var rounding: RoundingMode
    var implements: [String: Implement]

    init(
        bars: [String: Double] = [:],
        platePairs: [Double] = [],
        dumbbells: [Double] = [],
        rounding: RoundingMode = .nearest,
        implements: [String: Implement] = [:]
    ) {
        self.bars = bars
        self.platePairs = platePairs
        self.dumbbells = dumbbells
        self.rounding = rounding
        self.implements = implements
    }

    private enum CodingKeys: String, CodingKey {
        case bars
        case platePairs
        case dumbbells
        case rounding
        case implements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bars = try container.decodeIfPresent([String: Double].self, forKey: .bars) ?? [:]
        platePairs = try container.decodeIfPresent([Double].self, forKey: .platePairs) ?? []
        dumbbells = try container.decodeIfPresent([Double].self, forKey: .dumbbells) ?? []
        rounding = try container.decodeIfPresent(RoundingMode.self, forKey: .rounding) ?? .nearest
        implements = try container.decodeIfPresent([String: Implement].self, forKey: .implements) ?? [:]
    }
}

enum RoundingMode: String, Codable, Sendable, Hashable {
    case nearest
    case down
}

enum Implement: String, Codable, Sendable, Hashable {
    case barbell
    case dumbbell
    case bodyweight
}

struct PatchPlanEdit: Encodable, Sendable {
    var filename: String?
    var name: String
    var description: String
    var activeFrom: String?
    var expires: String?
    var operations: [PatchEditOperation]
}

enum PatchEditOperation: Encodable, Sendable, Hashable {
    case replaceExercise(from: String, to: String, laneRegex: String)
    case addConditioning(day: String, activity: String)
    case cap(target: String, value: String, laneRegex: String?)

    private enum CodingKeys: String, CodingKey {
        case op
        case from
        case to
        case laneRegex
        case day
        case activity
        case target
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .replaceExercise(let from, let to, let laneRegex):
            try container.encode("replace_exercise", forKey: .op)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(laneRegex, forKey: .laneRegex)
        case .addConditioning(let day, let activity):
            try container.encode("add_conditioning", forKey: .op)
            try container.encode(day, forKey: .day)
            try container.encode(activity, forKey: .activity)
        case .cap(let target, let value, let laneRegex):
            try container.encode("cap", forKey: .op)
            try container.encode(target, forKey: .target)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(laneRegex, forKey: .laneRegex)
        }
    }
}

struct SwitchProgramEdit: Encodable, Sendable {
    var template: String
    var planName: String?
    var units: Units
    var initialNumbers: [String: String]
    var suggestedDays: [String]?
    var date: String
    var note: String?
}

struct InitialNumberSuggestionRequest: Encodable, Sendable {
    var template: String
    var units: Units
}

struct LoadSuggestionRequest: Encodable, Sendable {
    var exercise: String
    var units: Units
}

struct InitialNumberSuggestions: Codable, Sendable, Hashable {
    var template: String
    var units: Units
    var values: [String: String]
    var suggestions: [InitialNumberSuggestion]
}

struct InitialNumberSuggestion: Codable, Sendable, Hashable, Identifiable {
    var exercise: String
    var value: String?
    var sourceExercise: String?
    var sourceDate: String?
    var sourceLoad: String?

    var id: String { exercise }
}

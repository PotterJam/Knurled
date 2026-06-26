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

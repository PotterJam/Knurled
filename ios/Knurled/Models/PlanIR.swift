import Foundation

struct PlanIR: Codable, Sendable, Hashable {
    struct Identity: Codable, Sendable, Hashable {
        var name: String
        var template: String
        var templateId: String
        var templateVersion: String
        var units: Units
    }

    struct Schedule: Codable, Sendable, Hashable {
        var mode: String
        var rotation: [String]
        var suggestedDays: [String]
    }

    var plan: Identity
    var schedule: Schedule
    var starts: [String: String]
    var trainingMaxes: [String: String]
    var accessories: [String: String]
    var exercises: [String: CustomExercise]
    var equipment: EquipmentProfile?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decode(Identity.self, forKey: .plan)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        starts = try container.decodeIfPresent([String: String].self, forKey: .starts) ?? [:]
        trainingMaxes = try container.decodeIfPresent([String: String].self, forKey: .trainingMaxes) ?? [:]
        accessories = try container.decodeIfPresent([String: String].self, forKey: .accessories) ?? [:]
        exercises = try container.decodeIfPresent([String: CustomExercise].self, forKey: .exercises) ?? [:]
        equipment = try container.decodeIfPresent(EquipmentProfile.self, forKey: .equipment)
    }

    static func load(dir: URL) throws -> PlanIR {
        let url = dir.appending(path: "build/current.ir.json")
        return try KnurledCoding.decoder().decode(PlanIR.self, from: Data(contentsOf: url))
    }
}

struct CustomExercise: Codable, Sendable, Hashable {
    var label: String
    var pattern: String?
    var implement: String?
}

struct ExerciseCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var pattern: String
    var muscles: [String]
    var implement: String?
    var custom: Bool

    init(
        id: String,
        label: String,
        pattern: String,
        muscles: [String] = [],
        implement: String? = nil,
        custom: Bool = false
    ) {
        self.id = id
        self.label = label
        self.pattern = pattern
        self.muscles = muscles
        self.implement = implement
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        pattern = try container.decode(String.self, forKey: .pattern)
        muscles = try container.decodeIfPresent([String].self, forKey: .muscles) ?? []
        implement = try container.decodeIfPresent(String.self, forKey: .implement)
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? false
    }
}

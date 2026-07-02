import Foundation

struct RenderedSession: Codable, Sendable, Hashable, Identifiable {
    var type: String
    var schemaVersion: String
    var engineVersion: String
    var sessionId: String
    var displayName: String
    /// The day's lifts at a glance ("Squat · Bench Press · Lat Pulldown"),
    /// composed by the engine (RFC-0001 D3).
    var displayDescription: String? = nil
    var suggestedDate: String?
    var planHash: String
    var templateHash: String
    var renderedSessionHash: String
    var items: [RenderedItem]

    var id: String { renderedSessionHash }
}

struct RenderedItem: Codable, Sendable, Hashable, Identifiable {
    var phase: RenderedItemPhase
    var itemId: String
    var slotId: String
    var progressionLane: String
    var progressionRule: String
    var exercise: String
    var implement: Implement?
    var display: DisplayFields
    var prescription: Prescription
    var executionContract: ExecutionContract
    var effectPreview: EffectPreview
    var rest: RestPrescription
    var identity: ItemIdentity
    var exerciseOptions: RenderedExerciseOptions?

    var id: String { itemId }

    init(
        phase: RenderedItemPhase = .main,
        itemId: String,
        slotId: String,
        progressionLane: String,
        progressionRule: String,
        exercise: String,
        implement: Implement? = nil,
        display: DisplayFields,
        prescription: Prescription,
        executionContract: ExecutionContract,
        effectPreview: EffectPreview,
        rest: RestPrescription,
        identity: ItemIdentity,
        exerciseOptions: RenderedExerciseOptions?
    ) {
        self.phase = phase
        self.itemId = itemId
        self.slotId = slotId
        self.progressionLane = progressionLane
        self.progressionRule = progressionRule
        self.exercise = exercise
        self.implement = implement
        self.display = display
        self.prescription = prescription
        self.executionContract = executionContract
        self.effectPreview = effectPreview
        self.rest = rest
        self.identity = identity
        self.exerciseOptions = exerciseOptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(RenderedItemPhase.self, forKey: .phase) ?? .main
        itemId = try container.decode(String.self, forKey: .itemId)
        slotId = try container.decode(String.self, forKey: .slotId)
        progressionLane = try container.decode(String.self, forKey: .progressionLane)
        progressionRule = try container.decode(String.self, forKey: .progressionRule)
        exercise = try container.decode(String.self, forKey: .exercise)
        implement = try container.decodeIfPresent(Implement.self, forKey: .implement)
        display = try container.decode(DisplayFields.self, forKey: .display)
        prescription = try container.decode(Prescription.self, forKey: .prescription)
        executionContract = try container.decode(ExecutionContract.self, forKey: .executionContract)
        effectPreview = try container.decode(EffectPreview.self, forKey: .effectPreview)
        rest = try container.decode(RestPrescription.self, forKey: .rest)
        identity = try container.decode(ItemIdentity.self, forKey: .identity)
        exerciseOptions = try container.decodeIfPresent(RenderedExerciseOptions.self, forKey: .exerciseOptions)
    }
}

enum RenderedItemPhase: String, Codable, Sendable, Hashable {
    case main
    case warmup
    case warmdown
}

struct DisplayFields: Codable, Sendable, Hashable {
    var title: String
    var subtitle: String
    /// Clean engine-owned exercise name ("Overhead Press") — render this, not
    /// raw lane/tier ids (RFC-0001 D3). Falls back to `title` for snapshots
    /// captured before the field existed.
    var label: String
    /// The lift's role in the program's own vocabulary ("Main lift").
    var group: String?

    init(title: String, subtitle: String, label: String = "", group: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.label = label.isEmpty ? title : label
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decode(String.self, forKey: .subtitle)
        let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        label = decodedLabel.isEmpty ? title : decodedLabel
        group = try container.decodeIfPresent(String.self, forKey: .group)
    }
}

struct Prescription: Codable, Sendable, Hashable {
    /// Ramp-up sets the engine renders ahead of the working `sets`. They are guidance only:
    /// never required for completion and never sent back to the engine, so they live in their
    /// own field. The engine omits the key entirely when a lift has no warmups, hence the
    /// decode default.
    var warmups: [PrescribedSet]
    var sets: [PrescribedSet]

    init(warmups: [PrescribedSet] = [], sets: [PrescribedSet]) {
        self.warmups = warmups
        self.sets = sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        warmups = try container.decodeIfPresent([PrescribedSet].self, forKey: .warmups) ?? []
        sets = try container.decode([PrescribedSet].self, forKey: .sets)
    }
}

struct PrescribedSet: Codable, Sendable, Hashable, Identifiable {
    var set: Int
    var load: String?
    var targetReps: Int
    var amrap: Bool
    var percentage: Int?
    var repMin: Int? = nil
    var repMax: Int? = nil

    var id: Int { self.set }
}

struct ExecutionContract: Codable, Sendable, Hashable {
    var recommendedInput: String
    var fallbackInputs: [String]
    var completionRule: String
    var eventTemplate: String
    var requiredForCompletion: Bool
    var inputSchema: InputSchema
}

struct InputSchema: Codable, Sendable, Hashable {
    var mode: String
    var fields: [InputField]
    var fallback: String?
}

struct InputField: Codable, Sendable, Hashable {
    var name: String
    var type: String
    var min: Int?
    var max: Int?
    var `default`: JSONValue?
    var required: Bool
}

struct EffectPreview: Codable, Sendable, Hashable {
    var pass: [Effect]
    var fail: [Effect]
    var adjustedToday: [Effect]
}

/// Mirrors `RestPrescription` from the engine: rest is resolved by the engine
/// (plan/template, by slot/lane/exercise/tier), never computed in the app.
struct RestPrescription: Codable, Sendable, Hashable {
    var seconds: Int
    var source: String
    var key: String
}

struct Effect: Codable, Sendable, Hashable {
    var op: String
    var lane: String
    var from: String?
    var to: String?
}

struct ItemIdentity: Codable, Sendable, Hashable {
    var itemId: String
    var slotId: String
    var progressionLane: String
    var progressionRule: String
    var planHash: String
    var renderedSessionHash: String
}

struct RenderedExerciseOptions: Codable, Sendable, Hashable {
    var primary: String
    var allowRuntimeSwap: Bool
    var defaultPolicy: SwapPolicy
    var alternatives: [ExerciseAlternative]
}

struct ExerciseAlternative: Codable, Sendable, Hashable, Identifiable {
    var optionId: String
    var exercise: String
    var label: String
    var policy: SwapPolicy

    var id: String { optionId }
}

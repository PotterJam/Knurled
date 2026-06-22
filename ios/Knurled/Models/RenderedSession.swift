import Foundation

struct RenderedSession: Codable, Sendable, Hashable, Identifiable {
    var type: String
    var schemaVersion: String
    var engineVersion: String
    var sessionId: String
    var displayName: String
    var suggestedDate: String?
    var planHash: String
    var templateHash: String
    var renderedSessionHash: String
    var items: [RenderedItem]

    var id: String { renderedSessionHash }
}

struct RenderedItem: Codable, Sendable, Hashable, Identifiable {
    var itemId: String
    var slotId: String
    var progressionLane: String
    var progressionRule: String
    var exercise: String
    var display: DisplayFields
    var prescription: Prescription
    var executionContract: ExecutionContract
    var effectPreview: EffectPreview
    var rest: RestPrescription
    var identity: ItemIdentity
    var exerciseOptions: RenderedExerciseOptions?

    var id: String { itemId }
}

struct DisplayFields: Codable, Sendable, Hashable {
    var title: String
    var subtitle: String
}

struct Prescription: Codable, Sendable, Hashable {
    var sets: [PrescribedSet]
}

struct PrescribedSet: Codable, Sendable, Hashable, Identifiable {
    var set: Int
    var load: String?
    var targetReps: Int
    var amrap: Bool
    var percentage: Int?

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

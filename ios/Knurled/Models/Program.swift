import Foundation

struct ProgramSummary: Codable, Sendable, Hashable, Identifiable {
    var slug: String
    var displayName: String
    var template: String
    var isActive: Bool
    var validity: ValidationStatus
    var nextSession: RenderedSession?

    var id: String { slug }
}

struct AddProgramRequest: Encodable, Sendable {
    var displayName: String
    var template: String
    var units: Units
    var initialNumbers: [String: String]
    var suggestedDays: [String]
    var customTemplate: String? = nil
    var equipment: EquipmentProfile? = nil
    var rest: RestPolicy? = nil
}

struct ProgramMutationOutcome: Codable, Sendable {
    var programs: [ProgramSummary]
    var changedFiles: [String]
}

struct ProgramAdjustmentSuggestion: Codable, Sendable, Hashable, Identifiable {
    var kind: String
    var lane: String
    var reason: String
    var proposedValue: String?
    /// Engine-owned human copy for the suggestion card (RFC-0001 D3);
    /// `reason` stays the technical explanation.
    var userDescription: String? = nil

    var id: String { "\(kind):\(lane)" }

    var displayText: String {
        if let userDescription, !userDescription.isEmpty { return userDescription }
        return reason
    }
}

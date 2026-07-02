import Foundation

struct ValidationReport: Codable, Sendable, Hashable {
    var type: String
    var schemaVersion: String
    var engineVersion: String
    var status: ValidationStatus
    var errors: [ValidationMessage]
    var warnings: [ValidationMessage]
    var checked: ValidationChecks

    var isValid: Bool { status == .valid }
}

struct ValidationMessage: Codable, Sendable, Hashable {
    var code: String
    var message: String
    /// Engine-owned human sentence for this problem (RFC-0001 D9). Absent
    /// only in reports written by older engines.
    var userMessage: String? = nil

    /// What the UI should show: the engine's user copy, falling back to the
    /// technical message for old reports.
    var displayText: String {
        if let userMessage, !userMessage.isEmpty { return userMessage }
        return message
    }
}

struct ValidationChecks: Codable, Sendable, Hashable {
    var planSyntax: Bool
    var templateLock: Bool
    var patchValidity: Bool
    var renderability: Bool
    var executionContracts: Bool
    var stateLogConsistency: Bool
    var generatedFileFreshness: Bool
}

struct ExecutionInputValidation: Codable, Sendable, Hashable {
    var type: String
    var schemaVersion: String
    var status: ValidationStatus
    var errors: [ValidationMessage]

    var isValid: Bool { status == .valid }
}

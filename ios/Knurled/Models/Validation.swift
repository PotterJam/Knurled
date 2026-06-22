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

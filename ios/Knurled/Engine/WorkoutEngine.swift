import Foundation

protocol WorkoutEngine: Sendable {
    func engineVersion() async throws -> String
    func builtinTemplates() async throws -> [StarterTemplate]
    func initRepo(dir: URL, template: String) async throws
    func validate(dir: URL) async throws -> ValidationReport
    func build(dir: URL, write: Bool) async throws -> BuildOutputs
    func reduce(dir: URL, session: RenderedSession, input: ExecutionInput) async throws -> ReductionOutcome
    func validateInput(dir: URL, input: ExecutionInput) async throws -> ExecutionInputValidation
    func renderSession(dir: URL, sessionId: String) async throws -> RenderedSession
}

struct ReductionOutcome: Sendable {
    var result: ReductionResult
    var eventLine: String?
}

enum EngineError: Error, Sendable, LocalizedError {
    case engine(String)
    case emptyResponse
    case missingData

    var errorDescription: String? {
        switch self {
        case .engine(let message): return message
        case .emptyResponse: return "The engine returned no response."
        case .missingData: return "The engine response was missing its payload."
        }
    }
}

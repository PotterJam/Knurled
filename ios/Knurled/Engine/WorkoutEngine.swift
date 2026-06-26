import Foundation

protocol WorkoutEngine: Sendable {
    func engineVersion() async throws -> String
    func builtinTemplates() async throws -> [StarterTemplate]
    func exerciseCatalog() async throws -> [ExerciseCatalogEntry]
    func initRepo(dir: URL, template: String) async throws
    func validate(dir: URL) async throws -> ValidationReport
    func build(dir: URL, write: Bool) async throws -> BuildOutputs
    func reduce(dir: URL, session: RenderedSession, input: ExecutionInput) async throws -> ReductionResult
    func submit(
        dir: URL,
        session: RenderedSession,
        input: ExecutionInput,
        mode: SubmitMode,
        date: String
    ) async throws -> SubmitOutcome
    func validateInput(dir: URL, input: ExecutionInput) async throws -> ExecutionInputValidation
    func renderSession(dir: URL, sessionId: String) async throws -> RenderedSession
    func previewPlanEdit(dir: URL, edit: PlanEdit) async throws -> PlanEditOutcome
    func applyPlanEdit(dir: URL, edit: PlanEdit) async throws -> PlanEditOutcome
    func suggestInitialNumbers(dir: URL, request: InitialNumberSuggestionRequest) async throws -> InitialNumberSuggestions
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

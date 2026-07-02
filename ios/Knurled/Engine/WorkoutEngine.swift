import Foundation

protocol WorkoutEngine: Sendable {
    func engineVersion() async throws -> String
    func builtinTemplates() async throws -> [StarterTemplate]
    func exerciseCatalog() async throws -> [ExerciseCatalogEntry]
    func initRepo(dir: URL, template: String) async throws
    func validate(dir: URL) async throws -> ValidationReport
    func build(dir: URL, write: Bool) async throws -> BuildOutputs
    func skipWorkout(dir: URL, forward: Bool) async throws -> BuildOutputs
    func records(dir: URL) async throws -> [TrainingRecord]
    func amendRecord(dir: URL, request: AmendRecordRequest) async throws -> AmendRecordOutcome
    func mergeRecordRepos(source: URL, target: URL) async throws -> [String]
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
    func suggestLoad(dir: URL, request: LoadSuggestionRequest) async throws -> InitialNumberSuggestion
    func listPrograms(dir: URL) async throws -> [ProgramSummary]
    func addProgram(dir: URL, request: AddProgramRequest) async throws -> ProgramMutationOutcome
    func setActiveProgram(dir: URL, slug: String) async throws -> ProgramMutationOutcome
    func deleteProgram(dir: URL, slug: String) async throws -> ProgramMutationOutcome
    func suggestProgramAdjustments(dir: URL) async throws -> [ProgramAdjustmentSuggestion]
    func renderTemplate(dsl: DslTemplate) async throws -> String
    func parseTemplate(text: String) async throws -> DslTemplate
    func previewTemplate(request: PreviewTemplateRequest) async throws -> TemplatePreview
}

enum EngineError: Error, Sendable, LocalizedError {
    case engine(String)
    /// Failure carrying the engine's typed detail (RFC-0001 D9): a stable
    /// `kind` to branch on and whether retrying can plausibly succeed.
    case typed(kind: String, retryable: Bool, message: String)
    case emptyResponse
    case missingData

    var errorDescription: String? {
        switch self {
        case .engine(let message): return message
        case .typed(_, _, let message): return message
        case .emptyResponse: return "The engine returned no response."
        case .missingData: return "The engine response was missing its payload."
        }
    }

    var isRetryable: Bool {
        if case .typed(_, let retryable, _) = self { return retryable }
        return false
    }
}

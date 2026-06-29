import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case needsConnection
        case ready
    }

    let engine: WorkoutEngine
    let repos: RepoManager
    let github: GitHubStore

    var phase: Phase = .launching
    var activeRepo: ActiveRepo?
    var engineVersion: String?
    var starterTemplates: [StarterTemplate] = []
    var exerciseCatalog: [ExerciseCatalogEntry] = []

    init(
        engine: WorkoutEngine = RustWorkoutEngine(),
        repos: RepoManager = RepoManager(),
        github: GitHubStore? = nil
    ) {
        self.engine = engine
        self.repos = repos
        self.github = github ?? GitHubStore()
    }

    func bootstrap() async {
        engineVersion = try? await engine.engineVersion()
        await loadStarterTemplates()
        await loadExerciseCatalog()
        await github.restore()
        if await restoreSelection() { return }
        await loadSampleRepo()
    }

    /// Loads the engine's built-in starter templates once. The app shows whatever the engine
    /// reports rather than a hardcoded list, so the two can't drift.
    func loadStarterTemplates() async {
        guard starterTemplates.isEmpty else { return }
        starterTemplates = (try? await engine.builtinTemplates()) ?? []
    }

    func loadExerciseCatalog() async {
        guard exerciseCatalog.isEmpty else { return }
        exerciseCatalog = (try? await engine.exerciseCatalog()) ?? []
    }

    func loadSampleRepo() async {
        do {
            let url = try repos.ensureSampleRepo()
            let repo = ActiveRepo(displayName: "Sample · GZCLP", url: url, isSample: true)
            await repo.refresh(engine: engine)
            activeRepo = repo
            phase = .ready
        } catch {
            phase = .needsConnection
        }
    }

    func refresh() async {
        await activeRepo?.refresh(engine: engine)
    }

    @discardableResult
    func addProgram(_ request: AddProgramRequest, in repo: ActiveRepo) async throws -> ProgramMutationOutcome {
        let outcome = try await engine.addProgram(dir: repo.url, request: request)
        await repo.refresh(engine: engine)
        try await pushProgramChange(outcome.changedFiles, in: repo, message: "Add program")
        return outcome
    }

    @discardableResult
    func setActiveProgram(_ slug: String, in repo: ActiveRepo) async throws -> ProgramMutationOutcome {
        let outcome = try await engine.setActiveProgram(dir: repo.url, slug: slug)
        await repo.refresh(engine: engine)
        try await pushProgramChange(outcome.changedFiles, in: repo, message: "Switch active program")
        return outcome
    }

    @discardableResult
    func deleteProgram(_ slug: String, in repo: ActiveRepo) async throws -> ProgramMutationOutcome {
        let outcome = try await engine.deleteProgram(dir: repo.url, slug: slug)
        await repo.refresh(engine: engine)
        try await pushProgramChange(outcome.changedFiles, in: repo, message: "Delete program")
        return outcome
    }

    /// Skips the next workout one rotation step forward or backward without recording
    /// anything or moving the lanes — only the schedule cursor moves (ADR 0007). Used when
    /// a few days were missed and the same rotation slot should be skipped, with no training
    /// record and no progression penalty. Persists the new cursor and best-effort pushes it.
    @discardableResult
    func skipWorkout(forward: Bool, in repo: ActiveRepo) async throws -> BuildOutputs {
        let before = repo.state?.cursor
        let outputs = try await engine.skipWorkout(dir: repo.url, forward: forward)
        await repo.refresh(engine: engine)
        // Going back from the program's very first workout is a no-op in the engine; don't
        // manufacture an empty commit for a cursor that didn't move.
        guard outputs.state.cursor != before else { return outputs }
        let session = outputs.nextWorkout?.sessionId.uppercased() ?? "workout"
        try await pushProgramChange(
            GitHubChangedFiles.present(in: repo.url),
            in: repo,
            message: "Skip to \(session)"
        )
        return outputs
    }

    private func pushProgramChange(_ files: [String], in repo: ActiveRepo, message: String) async throws {
        do {
            try await push(repo: repo, message: message, files: files)
        } catch {
            repo.pendingPush = true
            repo.loadError = "Saved locally. Couldn't push to GitHub yet: \(error.localizedDescription)"
        }
        persistSelection()
    }
}

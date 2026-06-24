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

    init(
        engine: WorkoutEngine = RustWorkoutEngine(),
        repos: RepoManager = RepoManager(),
        github: GitHubStore = GitHubStore()
    ) {
        self.engine = engine
        self.repos = repos
        self.github = github
    }

    func bootstrap() async {
        engineVersion = try? await engine.engineVersion()
        await loadStarterTemplates()
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
}

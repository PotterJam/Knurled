import Foundation
import Observation

@MainActor
@Observable
final class ActiveRepo: Identifiable {
    let id = UUID()
    let displayName: String
    let url: URL
    let isSample: Bool

    var outputs: BuildOutputs?
    var lastValidOutputs: BuildOutputs?
    var plan: PlanIR?
    var records: [DayRecord] = []
    var isRefreshing = false
    var loadError: String?
    var remote: GitHubRemote?
    var pendingPush = false

    init(displayName: String, url: URL, isSample: Bool) {
        self.displayName = displayName
        self.url = url
        self.isSample = isSample
    }

    private var displayOutputs: BuildOutputs? {
        if let outputs, outputs.validation.isValid { return outputs }
        return lastValidOutputs ?? outputs
    }

    var nextWorkout: RenderedSession? { displayOutputs?.nextWorkout }
    var state: StateProjection? { displayOutputs?.state }
    var validation: ValidationReport? { outputs?.validation }
    var isValid: Bool { outputs?.validation.isValid ?? false }

    func refresh(engine: WorkoutEngine, logs: LogReader = LogReader()) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let built = try await engine.build(dir: url, write: false)
            outputs = built
            if built.validation.isValid { lastValidOutputs = built }
            plan = try? PlanIR.load(dir: url)
            records = logs.records(dir: url)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

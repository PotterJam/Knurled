import Foundation
import Observation

@MainActor
@Observable
final class ActiveRepo: Identifiable {
    let id = UUID()
    let displayName: String
    let url: URL

    var outputs: BuildOutputs?
    var lastValidOutputs: BuildOutputs?
    var plan: PlanIR?
    var records: [TrainingRecord] = []
    var programs: [ProgramSummary] = []
    /// Engine-owned, global-history prefills keyed by normalized exercise name.
    var suggestedLoads: [String: String] = [:]
    var isRefreshing = false
    var loadError: String?
    var remote: GitHubRemote?
    var pendingPush = false

    init(displayName: String, url: URL) {
        self.displayName = displayName
        self.url = url
    }

    private var displayOutputs: BuildOutputs? {
        if let outputs, outputs.validation.isValid { return outputs }
        return lastValidOutputs ?? outputs
    }

    var nextWorkout: RenderedSession? { displayOutputs?.nextWorkout }
    var state: StateProjection? { displayOutputs?.state }
    var validation: ValidationReport? { outputs?.validation }
    var isValid: Bool { outputs?.validation.isValid ?? false }

    func refresh(engine: WorkoutEngine) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let built = try await engine.build(dir: url, write: false)
            outputs = built
            if built.validation.isValid { lastValidOutputs = built }
            plan = try? PlanIR.load(dir: url)
            records = try await engine.records(dir: url)
            programs = (try? await engine.listPrograms(dir: url)) ?? []
            suggestedLoads = [:]
            if let session = built.nextWorkout, let units = plan?.plan.units {
                let exercises = Set(session.items.compactMap { item in
                    item.prescription.sets.allSatisfy { $0.load == nil }
                        && item.implement != .bodyweight ? item.exercise : nil
                })
                for exercise in exercises {
                    let suggestion = try await engine.suggestLoad(
                        dir: url,
                        request: LoadSuggestionRequest(exercise: exercise, units: units)
                    )
                    if let value = suggestion.value {
                        suggestedLoads[LiveItem.normalized(exercise)] = "\(value)\(units.rawValue)"
                    }
                }
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

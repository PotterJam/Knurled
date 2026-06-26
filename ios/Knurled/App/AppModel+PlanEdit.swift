import Foundation

extension AppModel {
    func previewPlanEdit(_ edit: PlanEdit, in repo: ActiveRepo) async throws -> PlanEditOutcome {
        try await engine.previewPlanEdit(dir: repo.url, edit: edit)
    }

    @discardableResult
    func applyPlanEdit(_ edit: PlanEdit, in repo: ActiveRepo, message: String) async throws -> PlanEditOutcome {
        let outcome = try await engine.applyPlanEdit(dir: repo.url, edit: edit)
        guard outcome.applied else { return outcome }

        await repo.refresh(engine: engine)
        do {
            try await push(repo: repo, message: message, files: outcome.changedFiles)
        } catch {
            repo.pendingPush = true
            repo.loadError = "Saved locally. Couldn't push to GitHub yet: \(error.localizedDescription)"
        }
        persistSelection()
        return outcome
    }
}

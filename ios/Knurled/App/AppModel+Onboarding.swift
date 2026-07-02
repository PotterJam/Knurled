import Foundation

extension AppModel {
    /// Creates the user's training repo in primary storage (iCloud Drive when available):
    /// initializes the chosen starter template, applies their first-workout numbers, builds,
    /// and makes it the active repo. GitHub is not involved — a backup remote can be linked
    /// afterwards with `createBackupRepository` or from Settings.
    @discardableResult
    func createTrainingRepository(
        template: StarterTemplate,
        initialNumbers: InitialTrainingNumbers
    ) async throws -> ActiveRepo {
        let dir = try await repos.newWorkingDirectory(preferredSlug: "my-training")
        do {
            try await engine.initRepo(dir: dir, template: template.reference)
            try Self.apply(initialNumbers: initialNumbers, to: dir)
            _ = try await engine.build(dir: dir, write: true)
        } catch {
            // A half-initialized directory must not survive: it would shadow the slug and
            // make the next attempt silently reuse broken files.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        let repo = ActiveRepo(displayName: template.title, url: dir)
        await repo.refresh(engine: engine)
        activeRepo = repo
        phase = .ready
        persistSelection()
        return repo
    }

    static func apply(initialNumbers: InitialTrainingNumbers, to dir: URL) throws {
        let programDir = RepoLayout.activeProgramDirectory(in: dir)
        let planURL = programDir.appending(path: "plan.fitspec")
        var plan = try String(contentsOf: planURL, encoding: .utf8)
        plan = Self.replacingPlanUnits(in: plan, with: initialNumbers.units)
        plan = try Self.replacingInitialNumberBlock(in: plan, with: initialNumbers)
        try plan.write(to: planURL, atomically: true, encoding: .utf8)

        // `initRepo` wrote state from template defaults; drop it so build derives from the
        // edited first-workout numbers.
        let stateURL = programDir.appending(path: "state/current.json")
        if FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: stateURL)
        }
    }

    static func replacingPlanUnits(in plan: String, with units: Units) -> String {
        guard let range = plan.range(of: "\n  units ") else { return plan }
        let lineEnd = plan[range.upperBound...].firstIndex(of: "\n") ?? plan.endIndex
        var updated = plan
        updated.replaceSubrange(range.upperBound..<lineEnd, with: units.rawValue)
        return updated
    }

    static func replacingInitialNumberBlock(
        in plan: String,
        with initialNumbers: InitialTrainingNumbers
    ) throws -> String {
        let blockName = initialNumbers.spec.block.planBlockName
        let startMarker = "  \(blockName) {\n"
        guard let startRange = plan.range(of: startMarker) else {
            throw GitHubError.badResponse("Template plan is missing a \(blockName) block.")
        }
        guard let closeRange = plan[startRange.upperBound...].range(of: "\n  }") else {
            throw GitHubError.badResponse("Template plan has an unterminated \(blockName) block.")
        }

        let entries = try initialNumbers.planEntries()
            .map { exercise, load in #"    \#(exercise) "\#(load)""# }
            .joined(separator: "\n")
        let replacement = """
          \(blockName) {
        \(entries)
          }
        """

        var updated = plan
        updated.replaceSubrange(startRange.lowerBound..<closeRange.upperBound, with: replacement)
        return updated
    }
}

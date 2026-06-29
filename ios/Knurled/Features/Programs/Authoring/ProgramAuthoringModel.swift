import Foundation
import Observation

/// View-model behind the structured custom-program editor (Phase 6). It owns the
/// single editable `DslTemplate` plus the plan-level numbers, and debounces calls
/// to `knurled_preview_template` so every edit refreshes a live validation report
/// and a rendered first-workout preview without writing anything to disk. Save
/// renders the model back to canonical `.fitspec` via `knurled_render_template`
/// and hands it to `addProgram` — the engine stays the sole producer of DSL text.
@MainActor
@Observable
final class ProgramAuthoringModel {
    var name: String
    var template: DslTemplate
    var units: Units
    var initialNumbers: [String: String]
    var suggestedDays: Set<String>

    private(set) var validation: ValidationReport?
    private(set) var preview: RenderedSession?
    private(set) var isPreviewing = false
    private(set) var previewError: String?

    let engine: WorkoutEngine
    private var previewTask: Task<Void, Never>?

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    init(
        engine: WorkoutEngine,
        name: String,
        template: DslTemplate,
        units: Units = .kg,
        initialNumbers: [String: String] = [:],
        suggestedDays: Set<String> = ["mon", "wed", "fri"]
    ) {
        self.engine = engine
        self.name = name
        self.template = template
        self.units = units
        self.initialNumbers = initialNumbers
        self.suggestedDays = suggestedDays
    }

    /// A fresh, single-lane starter so a user never faces a blank canvas.
    static func blank(engine: WorkoutEngine, name: String = "My Program", units: Units = .kg) -> ProgramAuthoringModel {
        var template = DslTemplate(name: name, rotation: ["day"], restSeconds: 120)
        template.sessions = ["day": [DslSessionItem(lane: "squat.main", slotId: "day.squat")]]
        template.sessionDisplayNames = ["day": "Day"]
        template.lanes = [
            "squat.main": DslLane(
                exercise: "squat",
                tier: "main",
                basis: .workingWeight,
                sequence: .none,
                stages: [DslStage(id: "work", groups: [DslSetGroup(count: 3, reps: 5)])],
                rules: [DslRule(trigger: .pass, effects: [.increaseLoad(amount: "2.5")])]
            )
        ]
        return ProgramAuthoringModel(engine: engine, name: name, template: template, units: units)
    }

    // MARK: - Derived state

    var isValid: Bool { validation?.status == .valid }
    var errors: [ValidationMessage] { validation?.errors ?? [] }
    var warnings: [ValidationMessage] { validation?.warnings ?? [] }

    var selectedDays: [String] { Self.weekdays.filter(suggestedDays.contains) }

    /// Sessions in rotation order, falling back to sorted keys for any not yet
    /// placed in the rotation.
    var orderedSessionIds: [String] {
        var ids = template.rotation.filter { template.sessions[$0] != nil }
        for id in template.sessions.keys.sorted() where !ids.contains(id) { ids.append(id) }
        return ids
    }

    var sortedLaneIds: [String] { template.lanes.keys.sorted() }

    /// Distinct exercises that need an initial number, with the basis that
    /// decides whether it is a working weight or a training max. Bodyweight and
    /// `performed`-seeded working-weight lanes need none.
    var requiredStarts: [(exercise: String, basis: DslBasis)] {
        var seen = Set<String>()
        var result: [(String, DslBasis)] = []
        for id in sortedLaneIds {
            guard let lane = template.lanes[id] else { continue }
            switch lane.basis {
            case .bodyweight: continue
            case .workingWeight where lane.initial == .performed: continue
            default: break
            }
            if seen.insert(lane.exercise).inserted {
                result.append((lane.exercise, lane.basis))
            }
        }
        return result
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isValid
            && !suggestedDays.isEmpty
    }

    // MARK: - Live preview

    /// Debounced refresh. Call on every edit; the previous in-flight refresh is
    /// cancelled so only the latest model is previewed.
    func schedulePreview() {
        template.restSeconds = max(15, template.restSeconds)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            await self?.refreshPreview()
        }
    }

    func refreshPreview() async {
        isPreviewing = true
        previewError = nil
        let request = PreviewTemplateRequest(
            dsl: template,
            units: units,
            initialNumbers: normalizedInitialNumbers(),
            suggestedDays: selectedDays
        )
        do {
            let result = try await engine.previewTemplate(request: request)
            validation = result.validation
            preview = result.preview
        } catch {
            previewError = error.localizedDescription
            preview = nil
        }
        isPreviewing = false
    }

    // MARK: - Save

    func makeAddProgramRequest() async throws -> AddProgramRequest {
        let document = try await engine.renderTemplate(dsl: template)
        return AddProgramRequest(
            displayName: name,
            template: "custom",
            units: units,
            initialNumbers: normalizedInitialNumbers(),
            suggestedDays: selectedDays,
            customTemplate: document,
            rest: RestPolicy(defaultSeconds: template.restSeconds)
        )
    }

    /// Initial numbers keyed by normalized exercise with a units suffix, matching
    /// what the engine expects when seeding starts/training maxes.
    private func normalizedInitialNumbers() -> [String: String] {
        var result: [String: String] = [:]
        for start in requiredStarts {
            let raw = initialNumbers[start.exercise, default: ""]
            guard let value = InitialTrainingNumbers.normalizedPositiveNumber(raw) else { continue }
            result[start.exercise] = "\(value)\(units.rawValue)"
        }
        return result
    }

    // MARK: - Structural edits

    func addSession() {
        let id = uniqueKey(base: "day", existing: Set(template.sessions.keys))
        template.sessions[id] = []
        template.sessionDisplayNames[id] = id.capitalized
        template.rotation.append(id)
        schedulePreview()
    }

    func removeSession(_ id: String) {
        template.sessions[id] = nil
        template.sessionDisplayNames[id] = nil
        template.rotation.removeAll { $0 == id }
        schedulePreview()
    }

    func addItem(toSession sessionId: String, lane laneId: String) {
        let session = sessionShort(sessionId)
        let slot = "\(session).\(laneSlotSuffix(laneId))"
        template.sessions[sessionId, default: []].append(DslSessionItem(lane: laneId, slotId: slot))
        schedulePreview()
    }

    func addLane(exercise: String) {
        let normalized = LiveItem.normalized(exercise)
        let id = uniqueKey(base: "\(normalized).main", existing: Set(template.lanes.keys))
        template.lanes[id] = DslLane(
            exercise: normalized,
            tier: "main",
            basis: .workingWeight,
            stages: [DslStage(id: "work", groups: [DslSetGroup(count: 3, reps: 5)])],
            rules: [DslRule(trigger: .pass, effects: [.increaseLoad(amount: "2.5")])]
        )
        schedulePreview()
    }

    func removeLane(_ id: String) {
        template.lanes[id] = nil
        for session in template.sessions.keys {
            template.sessions[session]?.removeAll { $0.lane == id }
        }
        schedulePreview()
    }

    private func sessionShort(_ sessionId: String) -> String { sessionId }
    private func laneSlotSuffix(_ laneId: String) -> String {
        laneId.split(separator: ".").last.map(String.init) ?? laneId
    }

    private func uniqueKey(base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }
}

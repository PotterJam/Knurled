import SwiftUI

/// Structured custom-program editor (Phase 6). Edits a `DslTemplate` over forms
/// with a live, engine-validated preview of the next workout, then saves it into
/// the program bank via `addProgram`. No raw `.fitspec` is ever typed by hand.
struct ProgramAuthoringView: View {
    let repo: ActiveRepo
    @Bindable var model: ProgramAuthoringModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var newLaneExercise = "squat"

    var body: some View {
        Form {
            programSection
            initialNumbersSection
            sessionsSection
            lanesSection
            scheduleSection
            ProgramPreviewPane(model: model)
            if let saveError {
                Section { Text(saveError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Custom program")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(isSaving || !model.canSave)
            }
        }
        .task { await model.refreshPreview() }
        .onChange(of: model.template) { model.schedulePreview() }
        .onChange(of: model.units) { model.schedulePreview() }
        .onChange(of: model.initialNumbers) { model.schedulePreview() }
        .onChange(of: model.suggestedDays) { model.schedulePreview() }
    }

    // MARK: - Sections

    private var programSection: some View {
        Section("Program") {
            TextField("Name", text: $model.name)
            Picker("Units", selection: $model.units) {
                Text("kg").tag(Units.kg)
                Text("lb").tag(Units.lb)
            }
            Stepper(
                "Default rest: \(model.template.restSeconds / 60)m \(model.template.restSeconds % 60)s",
                value: $model.template.restSeconds, in: 15...600, step: 15)
        }
    }

    @ViewBuilder
    private var initialNumbersSection: some View {
        let starts = model.requiredStarts
        if !starts.isEmpty {
            Section("Starting numbers") {
                ForEach(starts, id: \.exercise) { start in
                    HStack {
                        Text(LiveItem.titleCase(start.exercise))
                        Spacer()
                        TextField(
                            start.basis == .trainingMax ? "Training max" : "Working weight",
                            text: numberBinding(start.exercise)
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 120)
                        Text(model.units.rawValue).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sessionsSection: some View {
        Section("Sessions") {
            ForEach(model.orderedSessionIds, id: \.self) { id in
                NavigationLink {
                    SessionEditorView(model: model, sessionId: id)
                } label: {
                    VStack(alignment: .leading) {
                        Text(model.template.sessionDisplayNames[id] ?? id)
                        Text("\(model.template.sessions[id]?.count ?? 0) items")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.removeSession(id) }
                }
            }
            Button {
                model.addSession()
            } label: {
                Label("Add session", systemImage: "plus")
            }
        }
    }

    private var lanesSection: some View {
        Section("Lanes") {
            ForEach(model.sortedLaneIds, id: \.self) { id in
                NavigationLink {
                    LaneEditorView(model: model, laneId: id)
                } label: {
                    VStack(alignment: .leading) {
                        Text(id)
                        if let lane = model.template.lanes[id] {
                            Text("\(LiveItem.titleCase(lane.exercise)) · \(lane.basis.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { model.removeLane(id) }
                }
            }
            HStack {
                TextField("Exercise", text: $newLaneExercise)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add lane") { model.addLane(exercise: newLaneExercise) }
                    .disabled(newLaneExercise.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var scheduleSection: some View {
        Section("Suggested days") {
            HStack {
                ForEach(ProgramAuthoringModel.weekdays, id: \.self) { day in
                    Button(day.prefix(1).uppercased()) {
                        if model.suggestedDays.contains(day) {
                            model.suggestedDays.remove(day)
                        } else {
                            model.suggestedDays.insert(day)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.suggestedDays.contains(day) ? .accentColor : .secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func numberBinding(_ exercise: String) -> Binding<String> {
        Binding(
            get: { model.initialNumbers[exercise, default: ""] },
            set: { model.initialNumbers[exercise] = $0 }
        )
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            do {
                let request = try await model.makeAddProgramRequest()
                _ = try await app.addProgram(request, in: repo)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

// MARK: - Preview pane

private struct ProgramPreviewPane: View {
    @Bindable var model: ProgramAuthoringModel

    var body: some View {
        Section("Preview") {
            if model.isPreviewing && model.preview == nil {
                ProgressView()
            }
            ForEach(model.errors, id: \.code) { error in
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            ForEach(model.warnings, id: \.code) { warning in
                Label(warning.message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange).font(.callout)
            }
            if let preview = model.preview {
                Text(preview.displayName).font(.headline)
                ForEach(preview.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.display.title).font(.subheadline.bold())
                        Text(item.display.subtitle).font(.caption).foregroundStyle(.secondary)
                        ForEach(item.prescription.sets) { set in
                            Text(setLine(set)).font(.caption.monospaced())
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if let previewError = model.previewError {
                Text(previewError).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private func setLine(_ set: PrescribedSet) -> String {
        let load = set.load ?? "—"
        let reps = set.amrap ? "\(set.targetReps)+" : "\(set.targetReps)"
        return "Set \(set.set): \(load) × \(reps)"
    }
}

// MARK: - Session editor

private struct SessionEditorView: View {
    @Bindable var model: ProgramAuthoringModel
    let sessionId: String

    var body: some View {
        Form {
            Section("Session") {
                TextField("Display name", text: displayNameBinding)
            }
            Section("Items") {
                ForEach(itemIndices, id: \.self) { index in
                    itemRow(index)
                }
                .onDelete { offsets in
                    model.template.sessions[sessionId]?.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    model.template.sessions[sessionId]?.move(fromOffsets: source, toOffset: destination)
                }
                Menu {
                    ForEach(model.sortedLaneIds, id: \.self) { laneId in
                        Button(laneId) { model.addItem(toSession: sessionId, lane: laneId) }
                    }
                } label: {
                    Label("Add item", systemImage: "plus")
                }
            }
        }
        .navigationTitle(model.template.sessionDisplayNames[sessionId] ?? sessionId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private var itemIndices: Range<Int> {
        0..<(model.template.sessions[sessionId]?.count ?? 0)
    }

    private func itemRow(_ index: Int) -> some View {
        let items = model.template.sessions[sessionId] ?? []
        let item = items[index]
        return Picker(item.slotId, selection: laneSelectionBinding(index)) {
            ForEach(model.sortedLaneIds, id: \.self) { Text($0).tag($0) }
        }
    }

    private func laneSelectionBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.template.sessions[sessionId]?[index].lane ?? "" },
            set: { model.template.sessions[sessionId]?[index].lane = $0 }
        )
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { model.template.sessionDisplayNames[sessionId] ?? "" },
            set: { model.template.sessionDisplayNames[sessionId] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Lane editor

private struct LaneEditorView: View {
    @Bindable var model: ProgramAuthoringModel
    let laneId: String

    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Lane") {
                Picker("Exercise", selection: lane.exercise) {
                    ForEach(app.exerciseCatalog) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }
                TextField("Tier (e.g. t1, main)", text: tierBinding)
                Picker("Basis", selection: lane.basis) {
                    ForEach(DslBasis.allCases) { Text($0.label).tag($0) }
                }
                initialPicker
                Picker("Sequence", selection: lane.sequence) {
                    ForEach(DslSequence.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Rest: \(restSeconds)s", value: restBinding, in: 0...600, step: 15)
            }

            Section("Stages") {
                ForEach(stageIndices, id: \.self) { index in
                    NavigationLink {
                        StageEditorView(stage: stageBinding(index))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(model.template.lanes[laneId]?.stages[index].id ?? "")
                            Text("\(model.template.lanes[laneId]?.stages[index].groups.count ?? 0) set groups")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in model.template.lanes[laneId]?.stages.remove(atOffsets: offsets) }
                Button {
                    model.template.lanes[laneId]?.stages.append(
                        DslStage(id: "stage \((model.template.lanes[laneId]?.stages.count ?? 0) + 1)",
                                 groups: [DslSetGroup()]))
                } label: { Label("Add stage", systemImage: "plus") }
            }

            Section("Rules") {
                ForEach(ruleIndices, id: \.self) { index in
                    NavigationLink {
                        RuleEditorView(rule: ruleBinding(index), stageIds: stageIds)
                    } label: {
                        Text(ruleSummary(index))
                    }
                }
                .onDelete { offsets in model.template.lanes[laneId]?.rules.remove(atOffsets: offsets) }
                rulePresetsMenu
                Button {
                    model.template.lanes[laneId]?.rules.append(
                        DslRule(trigger: .pass, effects: [.increaseLoad(amount: "2.5")]))
                } label: { Label("Add rule", systemImage: "plus") }
            }
        }
        .navigationTitle(laneId)
        .navigationBarTitleDisplayMode(.inline)
    }

    // Non-optional binding to the lane; the lane always exists while this view is shown.
    private var lane: Binding<DslLane> {
        Binding(
            get: { model.template.lanes[laneId] ?? DslLane(exercise: "") },
            set: { model.template.lanes[laneId] = $0 }
        )
    }

    private var initialPicker: some View {
        let binding = Binding<InitialKind>(
            get: {
                switch model.template.lanes[laneId]?.initial ?? .basis {
                case .basis: return .basis
                case .performed: return .performed
                case .percent: return .percent
                }
            },
            set: { kind in
                switch kind {
                case .basis: model.template.lanes[laneId]?.initial = .basis
                case .performed: model.template.lanes[laneId]?.initial = .performed
                case .percent: model.template.lanes[laneId]?.initial = .percent(80)
                }
            }
        )
        return Group {
            Picker("Initial load", selection: binding) {
                Text("From basis").tag(InitialKind.basis)
                Text("Percent of basis").tag(InitialKind.percent)
                Text("First performed").tag(InitialKind.performed)
            }
            if case .percent(let percentage) = model.template.lanes[laneId]?.initial {
                Stepper("Initial: \(percentage)%", value: percentBinding(percentage), in: 1...100, step: 5)
            }
        }
    }

    private enum InitialKind: Hashable { case basis, percent, performed }

    private func percentBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: {
                if case .percent(let value) = model.template.lanes[laneId]?.initial { return value }
                return current
            },
            set: { model.template.lanes[laneId]?.initial = .percent($0) }
        )
    }

    private var tierBinding: Binding<String> {
        Binding(
            get: { model.template.lanes[laneId]?.tier ?? "" },
            set: { model.template.lanes[laneId]?.tier = $0.isEmpty ? nil : $0 }
        )
    }

    private var restSeconds: Int { model.template.lanes[laneId]?.restSeconds ?? 0 }
    private var restBinding: Binding<Int> {
        Binding(
            get: { model.template.lanes[laneId]?.restSeconds ?? 0 },
            set: { model.template.lanes[laneId]?.restSeconds = $0 == 0 ? nil : $0 }
        )
    }

    private var stageIndices: Range<Int> { 0..<(model.template.lanes[laneId]?.stages.count ?? 0) }
    private var ruleIndices: Range<Int> { 0..<(model.template.lanes[laneId]?.rules.count ?? 0) }
    private var stageIds: [String] { model.template.lanes[laneId]?.stages.map(\.id) ?? [] }

    private func stageBinding(_ index: Int) -> Binding<DslStage> {
        Binding(
            get: { model.template.lanes[laneId]?.stages[index] ?? DslStage(id: "", groups: []) },
            set: { model.template.lanes[laneId]?.stages[index] = $0 }
        )
    }

    private func ruleBinding(_ index: Int) -> Binding<DslRule> {
        Binding(
            get: { model.template.lanes[laneId]?.rules[index] ?? DslRule(trigger: .pass, effects: []) },
            set: { model.template.lanes[laneId]?.rules[index] = $0 }
        )
    }

    private func ruleSummary(_ index: Int) -> String {
        guard let rule = model.template.lanes[laneId]?.rules[index] else { return "" }
        return "\(rule.trigger.label) → \(rule.effects.map(\.label).joined(separator: ", "))"
    }

    private var rulePresetsMenu: some View {
        Menu {
            Button("Linear + stall deload") {
                model.template.lanes[laneId]?.rules = [
                    DslRule(trigger: .pass, effects: [.increaseLoad(amount: "2.5")]),
                    DslRule(trigger: .stall(count: 3), effects: [.deload(percent: 90)]),
                ]
            }
            Button("GZCLP stage ladder") {
                model.template.lanes[laneId]?.rules = [
                    DslRule(trigger: .pass, effects: [.increaseLoad(amount: "2.5")]),
                    DslRule(trigger: .fail, effects: [.advanceStage]),
                ]
            }
            Button("Double progression") {
                model.template.lanes[laneId]?.rules = [
                    DslRule(trigger: .pass, effects: [.increaseReps(amount: 1)]),
                    DslRule(trigger: .rangeTop, effects: [.increaseLoad(amount: "2.5"), .resetReps]),
                ]
            }
            Button("5/3/1 wave") {
                model.template.lanes[laneId]?.rules = [
                    DslRule(trigger: .pass, effects: [.advanceStage]),
                    DslRule(trigger: .cycleEnd, effects: [.recomputeTm(amount: "2.5"), .resetStage, .advanceCycle]),
                ]
            }
        } label: {
            Label("Apply preset", systemImage: "wand.and.stars")
        }
    }
}

// MARK: - Stage editor

private struct StageEditorView: View {
    @Binding var stage: DslStage

    var body: some View {
        Form {
            Section("Stage") {
                TextField("Stage id (e.g. 5x3+)", text: $stage.id)
            }
            Section("Set groups") {
                ForEach($stage.groups, id: \.self) { $group in
                    SetGroupEditor(group: $group)
                }
                .onDelete { stage.groups.remove(atOffsets: $0) }
                Button {
                    stage.groups.append(DslSetGroup())
                } label: { Label("Add set group", systemImage: "plus") }
            }
        }
        .navigationTitle(stage.id)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetGroupEditor: View {
    @Binding var group: DslSetGroup

    var body: some View {
        VStack {
            Stepper("Sets: \(group.count)", value: $group.count, in: 1...20)
            Stepper("Reps: \(group.reps)", value: $group.reps, in: 0...50)
            Stepper("Intensity: \(group.intensity)%", value: $group.intensity, in: 1...150, step: 5)
            Toggle("AMRAP", isOn: $group.amrap)
            Toggle("Rep range (double progression)", isOn: rangeToggle)
            if group.repMin != nil {
                Stepper("Min reps: \(group.repMin ?? 0)", value: repMinBinding, in: 1...50)
                Stepper("Max reps: \(group.repMax ?? 0)", value: repMaxBinding, in: 1...50)
            }
        }
    }

    private var rangeToggle: Binding<Bool> {
        Binding(
            get: { group.repMin != nil },
            set: { on in
                if on {
                    group.repMin = group.reps
                    group.repMax = group.reps + 5
                } else {
                    group.repMin = nil
                    group.repMax = nil
                }
            }
        )
    }

    private var repMinBinding: Binding<Int> {
        Binding(get: { group.repMin ?? 0 }, set: { group.repMin = $0 })
    }
    private var repMaxBinding: Binding<Int> {
        Binding(get: { group.repMax ?? 0 }, set: { group.repMax = $0 })
    }
}

// MARK: - Rule editor

private struct RuleEditorView: View {
    @Binding var rule: DslRule
    let stageIds: [String]

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("When", selection: triggerKindBinding) {
                    ForEach(TriggerKind.allCases) { Text($0.label).tag($0) }
                }
                if case .amrapGte(let reps) = rule.trigger {
                    Stepper("AMRAP ≥ \(reps)", value: amrapBinding(reps), in: 1...50)
                }
                if case .stall(let count) = rule.trigger {
                    Stepper("After \(count) stalls", value: stallBinding(count), in: 1...10)
                }
                Picker("Stage scope", selection: stageScopeBinding) {
                    Text("Any stage").tag("")
                    ForEach(stageIds, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Effects") {
                ForEach($rule.effects, id: \.self) { $effect in
                    EffectEditor(effect: $effect)
                }
                .onDelete { rule.effects.remove(atOffsets: $0) }
                Menu {
                    Button("Increase load") { rule.effects.append(.increaseLoad(amount: "2.5")) }
                    Button("Deload %") { rule.effects.append(.deload(percent: 90)) }
                    Button("Reset load %") { rule.effects.append(.resetLoad(percent: 90)) }
                    Button("Advance stage") { rule.effects.append(.advanceStage) }
                    Button("Reset stage") { rule.effects.append(.resetStage) }
                    Button("Increase reps") { rule.effects.append(.increaseReps(amount: 1)) }
                    Button("Reset reps") { rule.effects.append(.resetReps) }
                    Button("Recompute TM") { rule.effects.append(.recomputeTm(amount: "2.5")) }
                    Button("Advance cycle") { rule.effects.append(.advanceCycle) }
                } label: { Label("Add effect", systemImage: "plus") }
            }
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
    }

    private enum TriggerKind: String, CaseIterable, Identifiable {
        case pass, fail, amrapGte, stall, cycleEnd, rangeTop
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pass: return "Pass"
            case .fail: return "Fail"
            case .amrapGte: return "AMRAP ≥ N"
            case .stall: return "Stall (n)"
            case .cycleEnd: return "Cycle end"
            case .rangeTop: return "Range top"
            }
        }
    }

    private var triggerKindBinding: Binding<TriggerKind> {
        Binding(
            get: {
                switch rule.trigger {
                case .pass: return .pass
                case .fail: return .fail
                case .amrapGte: return .amrapGte
                case .stall: return .stall
                case .cycleEnd: return .cycleEnd
                case .rangeTop: return .rangeTop
                }
            },
            set: { kind in
                switch kind {
                case .pass: rule.trigger = .pass
                case .fail: rule.trigger = .fail
                case .amrapGte: rule.trigger = .amrapGte(reps: 5)
                case .stall: rule.trigger = .stall(count: 3)
                case .cycleEnd: rule.trigger = .cycleEnd
                case .rangeTop: rule.trigger = .rangeTop
                }
            }
        )
    }

    private func amrapBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: { if case .amrapGte(let reps) = rule.trigger { return reps }; return current },
            set: { rule.trigger = .amrapGte(reps: $0) }
        )
    }

    private func stallBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: { if case .stall(let count) = rule.trigger { return count }; return current },
            set: { rule.trigger = .stall(count: $0) }
        )
    }

    private var stageScopeBinding: Binding<String> {
        Binding(
            get: { rule.stage ?? "" },
            set: { rule.stage = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct EffectEditor: View {
    @Binding var effect: DslEffect

    var body: some View {
        switch effect {
        case .increaseLoad(let amount):
            HStack {
                Text("Increase load by")
                TextField("2.5 or 5%", text: amountBinding(amount, set: { .increaseLoad(amount: $0) }))
                    .multilineTextAlignment(.trailing)
            }
        case .recomputeTm(let amount):
            HStack {
                Text("Recompute TM by")
                TextField("2.5 or 5%", text: amountBinding(amount, set: { .recomputeTm(amount: $0) }))
                    .multilineTextAlignment(.trailing)
            }
        case .deload(let percent):
            Stepper("Deload to \(percent)%", value: percentBinding(percent, set: { .deload(percent: $0) }), in: 1...100, step: 5)
        case .resetLoad(let percent):
            Stepper("Reset load to \(percent)%", value: percentBinding(percent, set: { .resetLoad(percent: $0) }), in: 1...100, step: 5)
        case .increaseReps(let amount):
            Stepper("Increase reps by \(amount)", value: intBinding(amount, set: { .increaseReps(amount: $0) }), in: 1...10)
        case .advanceStage: Text("Advance stage")
        case .resetStage: Text("Reset stage")
        case .resetReps: Text("Reset reps")
        case .advanceCycle: Text("Advance cycle")
        }
    }

    private func amountBinding(_ current: String, set: @escaping (String) -> DslEffect) -> Binding<String> {
        Binding(get: { current }, set: { effect = set($0) })
    }
    private func percentBinding(_ current: Int, set: @escaping (Int) -> DslEffect) -> Binding<Int> {
        Binding(get: { current }, set: { effect = set($0) })
    }
    private func intBinding(_ current: Int, set: @escaping (Int) -> DslEffect) -> Binding<Int> {
        Binding(get: { current }, set: { effect = set($0) })
    }
}

// MARK: - Labels

extension DslTrigger {
    var label: String {
        switch self {
        case .pass: return "On pass"
        case .fail: return "On fail"
        case .amrapGte(let reps): return "AMRAP ≥ \(reps)"
        case .stall(let count): return "Stall ×\(count)"
        case .cycleEnd: return "Cycle end"
        case .rangeTop: return "Range top"
        }
    }
}

extension DslEffect {
    var label: String {
        switch self {
        case .increaseLoad(let amount): return "+\(amount) load"
        case .deload(let percent): return "deload \(percent)%"
        case .resetLoad(let percent): return "reset \(percent)%"
        case .advanceStage: return "advance stage"
        case .resetStage: return "reset stage"
        case .increaseReps(let amount): return "+\(amount) reps"
        case .resetReps: return "reset reps"
        case .recomputeTm(let amount): return "recompute TM +\(amount)"
        case .advanceCycle: return "advance cycle"
        }
    }
}

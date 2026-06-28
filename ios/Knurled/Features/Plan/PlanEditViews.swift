import SwiftUI

struct QuickPlanEditView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    @Environment(AppModel.self) private var app
    @State private var selectedDays: Set<String>
    @State private var barWeight: Double?
    @State private var selectedPlates: Set<Double>
    @State private var dumbbellValues: [Double]
    @State private var dumbbellPreset: DumbbellPreset
    @State private var rounding: RoundingMode
    @State private var warmupExercises: [SessionExercise]
    @State private var warmdownExercises: [SessionExercise]
    @State private var restSeconds: Int
    @State private var isSaving = false
    @State private var outcome: PlanEditOutcome?
    @State private var errorMessage: String?

    init(repo: ActiveRepo, plan: PlanIR) {
        self.repo = repo
        self.plan = plan
        let equipment = plan.equipment
        let currentDumbbells = equipment?.dumbbells ?? []
        _selectedDays = State(initialValue: Set(plan.schedule.suggestedDays))
        _barWeight = State(initialValue: equipment?.bars["default"])
        _selectedPlates = State(initialValue: Set(equipment?.platePairs ?? []))
        _dumbbellValues = State(initialValue: currentDumbbells)
        _dumbbellPreset = State(initialValue: DumbbellPreset.matching(values: currentDumbbells, units: plan.plan.units))
        _rounding = State(initialValue: equipment?.rounding ?? .nearest)
        _warmupExercises = State(initialValue: plan.sessionExercises.warmup)
        _warmdownExercises = State(initialValue: plan.sessionExercises.warmdown)
        _restSeconds = State(initialValue: plan.rest.defaultSeconds ?? 120)
    }

    var body: some View {
        Form {
            PlanEditOutcomeSection(outcome: outcome, errorMessage: errorMessage)

            Section("Suggested days") {
                WeekdayPicker(days: Self.days, selected: $selectedDays)
            }

            EquipmentEditor(
                units: plan.plan.units,
                barWeight: $barWeight,
                selectedPlates: $selectedPlates,
                dumbbellValues: $dumbbellValues,
                dumbbellPreset: $dumbbellPreset,
                rounding: $rounding
            )

            Section {
                Stepper("Default: \(restSeconds / 60)m \(restSeconds % 60)s", value: $restSeconds, in: 15...600, step: 15)
            } header: {
                Text("Rest")
            } footer: {
                Text("Exercise, lane, slot, and tier overrides remain unchanged.")
            }

            SessionExercisesEditor(
                title: "Warmup",
                systemImage: "figure.flexibility",
                exercises: $warmupExercises
            )
            SessionExercisesEditor(
                title: "Warmdown",
                systemImage: "figure.cooldown",
                exercises: $warmdownExercises
            )
        }
        .navigationTitle("Quick Edits")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(isSaving)
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
    }

    private func save() {
        let equipment = EquipmentProfile(
            bars: barWeight.map { ["default": $0] } ?? [:],
            platePairs: sortedPlates,
            dumbbells: dumbbellValues,
            rounding: rounding,
            implements: plan.equipment?.implements ?? [:]
        )
        let edit = PlanEdit.quick(
            QuickPlanEdit(
                suggestedDays: Self.days.filter { selectedDays.contains($0) },
                equipment: equipment,
                customExercise: nil,
                accessory: nil,
                sessionExercises: SessionExercisePolicy(
                    warmup: warmupExercises.filter { !$0.exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                    warmdown: warmdownExercises.filter { !$0.exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ),
                rest: RestPolicy(
                    defaultSeconds: restSeconds,
                    byTier: plan.rest.byTier,
                    bySlot: plan.rest.bySlot,
                    byLane: plan.rest.byLane,
                    byExercise: plan.rest.byExercise
                )
            )
        )
        apply(edit, message: "Update plan settings")
    }

    private var sortedPlates: [Double] {
        selectedPlates.sorted(by: >)
    }

    private func apply(_ edit: PlanEdit, message: String) {
        isSaving = true
        errorMessage = nil
        outcome = nil
        Task {
            do {
                outcome = try await app.applyPlanEdit(edit, in: repo, message: message)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

/// A compact week strip: one tappable circle per day instead of seven full-width toggles.
private struct WeekdayPicker: View {
    let days: [String]
    @Binding var selected: Set<String>

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.self) { day in
                let isOn = selected.contains(day)
                Button {
                    if isOn { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(Self.letter(day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? Color.white : .primary)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(isOn ? palette.accent : Color(uiColor: .tertiarySystemFill))
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.capitalized)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private static func letter(_ day: String) -> String {
        String(day.prefix(1)).uppercased()
    }
}

private struct EquipmentEditor: View {
    let units: Units
    @Binding var barWeight: Double?
    @Binding var selectedPlates: Set<Double>
    @Binding var dumbbellValues: [Double]
    @Binding var dumbbellPreset: DumbbellPreset
    @Binding var rounding: RoundingMode

    var body: some View {
        Section {
            Picker("Default bar", selection: $barWeight) {
                Text("None").tag(Optional<Double>.none)
                ForEach(barOptions, id: \.self) { weight in
                    Text(weightLabel(weight)).tag(Optional(weight))
                }
            }

            DisclosureGroup {
                ForEach(plateOptions, id: \.self) { plate in
                    Toggle(weightLabel(plate), isOn: plateBinding(plate))
                }
            } label: {
                LabeledContent("Plate pairs per side", value: plateSummary)
            }

            Picker("Dumbbells", selection: $dumbbellPreset) {
                ForEach(DumbbellPreset.options(for: units), id: \.self) { preset in
                    Text(preset.title(units: units)).tag(preset)
                }
                if !DumbbellPreset.options(for: units).contains(dumbbellPreset) {
                    Text("Current list").tag(dumbbellPreset)
                }
            }
            .onChange(of: dumbbellPreset) { _, preset in
                guard let values = preset.values(units: units) else { return }
                dumbbellValues = values
            }

            if !dumbbellValues.isEmpty {
                Text(dumbbellSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Rounding", selection: $rounding) {
                Text("Nearest achievable").tag(RoundingMode.nearest)
                Text("Always round down").tag(RoundingMode.down)
            }
        } header: {
            Text("Equipment")
        } footer: {
            Text("Plates are pairs available on each side of a bar. Dumbbells are total dumbbell weights available in the gym.")
        }
    }

    private var barOptions: [Double] {
        mergedOptions(defaults: units == .kg ? [20, 15, 10, 7.5] : [45, 35, 15], current: barWeight.map { [$0] } ?? [])
    }

    private var plateOptions: [Double] {
        mergedOptions(
            defaults: units == .kg ? [25, 20, 15, 10, 5, 2.5, 1.25, 0.5] : [45, 35, 25, 10, 5, 2.5, 1.25],
            current: Array(selectedPlates)
        )
        .sorted(by: >)
    }

    private var plateSummary: String {
        guard !selectedPlates.isEmpty else { return "None" }
        return selectedPlates.sorted(by: >).map(weightLabel).joined(separator: ", ")
    }

    private var dumbbellSummary: String {
        guard let first = dumbbellValues.first, let last = dumbbellValues.last else { return "No dumbbells" }
        return "\(dumbbellValues.count) weights, \(weightLabel(first)) to \(weightLabel(last))"
    }

    private func plateBinding(_ plate: Double) -> Binding<Bool> {
        Binding(
            get: { selectedPlates.contains(plate) },
            set: { enabled in
                if enabled {
                    selectedPlates.insert(plate)
                } else {
                    selectedPlates.remove(plate)
                }
            }
        )
    }

    private func mergedOptions(defaults: [Double], current: [Double]) -> [Double] {
        Array(Set(defaults + current)).sorted()
    }

    private func weightLabel(_ value: Double) -> String {
        "\(Self.formatNumber(value))\(units.rawValue)"
    }

    private static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded == value { return String(Int(rounded)) }
        return String(value)
    }
}

private enum DumbbellPreset: Hashable {
    case none
    case kgHome
    case kgCommercial
    case kgHeavy
    case lbHome
    case lbCommercial
    case lbHeavy
    case current

    static func options(for units: Units) -> [DumbbellPreset] {
        units == .kg ? [.none, .kgHome, .kgCommercial, .kgHeavy] : [.none, .lbHome, .lbCommercial, .lbHeavy]
    }

    static func matching(values: [Double], units: Units) -> DumbbellPreset {
        for preset in options(for: units) where preset.values(units: units) == values {
            return preset
        }
        return values.isEmpty ? .none : .current
    }

    func title(units: Units) -> String {
        switch self {
        case .none:
            return "None"
        case .kgHome:
            return "Home set: 2-20kg by 2kg"
        case .kgCommercial:
            return "Commercial: 2.5-30kg by 2.5kg"
        case .kgHeavy:
            return "Heavy: 5-50kg by 2.5kg"
        case .lbHome:
            return "Home set: 5-50lb by 5lb"
        case .lbCommercial:
            return "Commercial: 2.5-50lb by 2.5lb"
        case .lbHeavy:
            return "Heavy: 5-100lb by 5lb"
        case .current:
            return "Current list"
        }
    }

    func values(units: Units) -> [Double]? {
        switch self {
        case .none:
            return []
        case .kgHome:
            return Self.stepped(from: 2, through: 20, by: 2)
        case .kgCommercial:
            return Self.stepped(from: 2.5, through: 30, by: 2.5)
        case .kgHeavy:
            return Self.stepped(from: 5, through: 50, by: 2.5)
        case .lbHome:
            return Self.stepped(from: 5, through: 50, by: 5)
        case .lbCommercial:
            return Self.stepped(from: 2.5, through: 50, by: 2.5)
        case .lbHeavy:
            return Self.stepped(from: 5, through: 100, by: 5)
        case .current:
            return nil
        }
    }

    private static func stepped(from start: Double, through end: Double, by step: Double) -> [Double] {
        var values: [Double] = []
        var current = start
        while current <= end + 0.0001 {
            values.append((current * 10).rounded() / 10)
            current += step
        }
        return values
    }
}

private struct SessionExercisesEditor: View {
    let title: String
    let systemImage: String
    @Binding var exercises: [SessionExercise]

    /// Which row is open for editing. Only one expands at a time; everything else stays as a thin
    /// summary line. A freshly added exercise opens automatically.
    @State private var expandedIndex: Int?

    var body: some View {
        Section {
            if exercises.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            }
            ForEach(exercises.indices, id: \.self) { index in
                SessionExerciseRow(
                    exercise: $exercises[index],
                    isExpanded: expandedIndex == index,
                    onToggle: {
                        withAnimation(.snappy) {
                            expandedIndex = expandedIndex == index ? nil : index
                        }
                    }
                )
            }
            .onDelete { offsets in
                exercises.remove(atOffsets: offsets)
                expandedIndex = nil
            }
            .onMove { offsets, destination in
                exercises.move(fromOffsets: offsets, toOffset: destination)
                expandedIndex = nil
            }

            Button {
                exercises.append(SessionExercise(exercise: "", sets: 1, reps: title == "Warmdown" ? 60 : 10))
                expandedIndex = exercises.count - 1
            } label: {
                Label("Add \(title.lowercased()) exercise", systemImage: "plus.circle")
            }
        } header: {
            Label(title, systemImage: systemImage)
        } footer: {
            Text("Tap an exercise to edit its sets and reps. Use Edit to reorder.")
        }
    }
}

private struct SessionExerciseRow: View {
    @Binding var exercise: SessionExercise
    let isExpanded: Bool
    let onToggle: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        if isExpanded {
            expanded
        } else {
            summary
        }
    }

    private var summary: some View {
        Button(action: onToggle) {
            HStack {
                Text(exercise.exercise.isEmpty ? "New exercise" : exercise.exercise)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(exercise.exercise.isEmpty ? .secondary : .primary)
                Spacer()
                Text(summaryDetail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summaryDetail: String {
        var parts: [String] = []
        if let detail = exercise.load ?? exercise.note, !detail.isEmpty { parts.append(detail) }
        parts.append("\(exercise.sets)×\(exercise.reps)")
        return parts.joined(separator: " · ")
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Exercise", text: $exercise.exercise)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.weight(.medium))
                    .focused($nameFocused)
                Button(action: onToggle) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse")
            }

            TextField("load or note", text: loadOrNoteBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)

            HStack(spacing: 14) {
                labeledPicker("Sets", value: $exercise.sets, range: 1...20)
                labeledPicker("Reps", value: $exercise.reps, range: 0...99)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            if exercise.exercise.isEmpty { nameFocused = true }
        }
    }

    @ViewBuilder
    private func labeledPicker(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HorizontalNumberPicker(value: value, range: range)
        }
    }

    private var loadOrNoteBinding: Binding<String> {
        Binding(
            get: { exercise.load ?? exercise.note ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    exercise.load = nil
                    exercise.note = nil
                } else if trimmed.rangeOfCharacter(from: .decimalDigits) != nil {
                    exercise.load = trimmed
                    exercise.note = nil
                } else {
                    exercise.load = nil
                    exercise.note = trimmed
                }
            }
        )
    }
}

struct PatchPlanEditView: View {
    enum OperationKind: String, CaseIterable, Identifiable {
        case replaceExercise
        case addConditioning
        case cap

        var id: String { rawValue }

        var title: String {
            switch self {
            case .replaceExercise: "Replace exercise"
            case .addConditioning: "Add conditioning"
            case .cap: "Cap target"
            }
        }
    }

    let repo: ActiveRepo
    @Environment(AppModel.self) private var app

    @State private var name = ""
    @State private var description = ""
    @State private var activeFrom = ""
    @State private var expires = ""
    @State private var operation = OperationKind.replaceExercise
    @State private var from = ""
    @State private var to = ""
    @State private var laneRegex = ""
    @State private var day = "sat"
    @State private var activity = ""
    @State private var target = "rpe"
    @State private var value = "8"
    @State private var isSaving = false
    @State private var outcome: PlanEditOutcome?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            PlanEditOutcomeSection(outcome: outcome, errorMessage: errorMessage)

            Section("Patch") {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
                TextField("Active from", text: $activeFrom)
                    .textInputAutocapitalization(.never)
                TextField("Expires", text: $expires)
                    .textInputAutocapitalization(.never)
            }

            Section("Operation") {
                Picker("Type", selection: $operation) {
                    ForEach(OperationKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                switch operation {
                case .replaceExercise:
                    TextField("From", text: $from)
                        .textInputAutocapitalization(.never)
                    TextField("To", text: $to)
                        .textInputAutocapitalization(.never)
                    TextField("Lane regex", text: $laneRegex)
                        .textInputAutocapitalization(.never)
                case .addConditioning:
                    TextField("Day", text: $day)
                        .textInputAutocapitalization(.never)
                    TextField("Activity", text: $activity)
                case .cap:
                    TextField("Target", text: $target)
                        .textInputAutocapitalization(.never)
                    TextField("Value", text: $value)
                    TextField("Lane regex", text: $laneRegex)
                        .textInputAutocapitalization(.never)
                }
            }
        }
        .navigationTitle("Add Patch")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        let op: PatchEditOperation = switch operation {
        case .replaceExercise:
            .replaceExercise(from: from, to: to, laneRegex: laneRegex)
        case .addConditioning:
            .addConditioning(day: day, activity: activity)
        case .cap:
            .cap(target: target, value: value, laneRegex: laneRegex.nilIfBlank)
        }
        let edit = PlanEdit.savePatch(
            PatchPlanEdit(
                filename: nil,
                name: name,
                description: description,
                activeFrom: activeFrom.nilIfBlank,
                expires: expires.nilIfBlank,
                operations: [op]
            )
        )
        apply(edit, message: "Update plan patch")
    }

    private func apply(_ edit: PlanEdit, message: String) {
        isSaving = true
        errorMessage = nil
        outcome = nil
        Task {
            do {
                outcome = try await app.applyPlanEdit(edit, in: repo, message: message)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct SwitchProgramView: View {
    let repo: ActiveRepo
    @Environment(AppModel.self) private var app

    @State private var template: StarterTemplate?
    @State private var units: Units = .kg
    @State private var values: [String: String] = [:]
    @State private var suggestions: InitialNumberSuggestions?
    @State private var note = ""
    @State private var isSaving = false
    @State private var outcome: PlanEditOutcome?
    @State private var errorMessage: String?

    private var spec: InitialTrainingNumbers.Spec {
        InitialTrainingNumbers.spec(for: template)
    }

    private var canSave: Bool {
        template != nil && InitialTrainingNumbers.isComplete(values: values, for: spec)
    }

    var body: some View {
        Form {
            PlanEditOutcomeSection(outcome: outcome, errorMessage: errorMessage)

            Section("Template") {
                Picker("Program", selection: $template) {
                    ForEach(app.starterTemplates) { template in
                        VStack(alignment: .leading) {
                            Text(template.title)
                            Text(template.reference)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(template))
                    }
                }
                if let subtitle = template?.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            InitialTrainingNumbersEditor(spec: spec, units: $units, values: $values)

            if let suggestions {
                Section("Suggested from history") {
                    ForEach(suggestions.suggestions) { suggestion in
                        HStack {
                            Text(suggestion.exercise.replacingOccurrences(of: "_", with: " ").capitalized)
                            Spacer()
                            if let value = suggestion.value,
                               let date = suggestion.sourceDate,
                               let load = suggestion.sourceLoad {
                                Text("\(value)\(suggestions.units.rawValue) from \(load) on \(date)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No match")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("History") {
                TextField("Note", text: $note)
            }
        }
        .navigationTitle("Switch Program")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    if isSaving { ProgressView() } else { Text("Switch") }
                }
                .disabled(isSaving || !canSave)
            }
        }
        .task {
            await app.loadStarterTemplates()
            if template == nil {
                template = app.starterTemplates.first
                values = InitialTrainingNumbers.emptyValues(for: spec)
                await loadSuggestions()
            }
        }
        .onChange(of: template) { _, _ in
            values = InitialTrainingNumbers.emptyValues(for: spec)
            suggestions = nil
            Task { await loadSuggestions() }
        }
        .onChange(of: units) { _, _ in
            values = InitialTrainingNumbers.emptyValues(for: spec)
            suggestions = nil
            Task { await loadSuggestions() }
        }
    }

    private func save() {
        guard let template else { return }
        let numbers = Dictionary(uniqueKeysWithValues: spec.fields.compactMap { field -> (String, String)? in
            guard let number = InitialTrainingNumbers.normalizedPositiveNumber(values[field.exercise, default: ""])
            else { return nil }
            return (field.exercise, "\(number)\(units.rawValue)")
        })
        let edit = PlanEdit.switchProgram(
            SwitchProgramEdit(
                template: template.reference,
                planName: nil,
                units: units,
                initialNumbers: numbers,
                suggestedDays: nil,
                date: Self.todayString(),
                note: note.nilIfBlank
            )
        )
        apply(edit, message: "Switch program to \(template.title)")
    }

    private func apply(_ edit: PlanEdit, message: String) {
        isSaving = true
        errorMessage = nil
        outcome = nil
        Task {
            do {
                outcome = try await app.applyPlanEdit(edit, in: repo, message: message)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func loadSuggestions() async {
        guard let template else { return }
        do {
            let result = try await app.engine.suggestInitialNumbers(
                dir: repo.url,
                request: InitialNumberSuggestionRequest(template: template.reference, units: units)
            )
            suggestions = result
            for (exercise, value) in result.values {
                values[exercise] = value
            }
        } catch {
            suggestions = nil
        }
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct PlanEditOutcomeSection: View {
    let outcome: PlanEditOutcome?
    let errorMessage: String?

    var body: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } else if let outcome {
            Section {
                if outcome.outputs.validation.isValid && outcome.applied {
                    Label("Saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if outcome.outputs.validation.isValid {
                    Label("Preview valid", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ForEach(Array(outcome.outputs.validation.errors.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                            Text(message.message)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

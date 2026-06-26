import SwiftUI

struct QuickPlanEditView: View {
    let repo: ActiveRepo
    let plan: PlanIR

    @Environment(AppModel.self) private var app
    @State private var selectedDays: Set<String>
    @State private var barWeight: String
    @State private var plates: String
    @State private var dumbbells: String
    @State private var rounding: RoundingMode
    @State private var warmupExercises: [SessionExercise]
    @State private var warmdownExercises: [SessionExercise]
    @State private var isSaving = false
    @State private var outcome: PlanEditOutcome?
    @State private var errorMessage: String?

    init(repo: ActiveRepo, plan: PlanIR) {
        self.repo = repo
        self.plan = plan
        let equipment = plan.equipment
        _selectedDays = State(initialValue: Set(plan.schedule.suggestedDays))
        _barWeight = State(initialValue: equipment?.bars["default"].map(Self.formatNumber) ?? "")
        _plates = State(initialValue: (equipment?.platePairs ?? []).map(Self.formatNumber).joined(separator: " "))
        _dumbbells = State(initialValue: (equipment?.dumbbells ?? []).map(Self.formatNumber).joined(separator: " "))
        _rounding = State(initialValue: equipment?.rounding ?? .nearest)
        _warmupExercises = State(initialValue: plan.sessionExercises.warmup)
        _warmdownExercises = State(initialValue: plan.sessionExercises.warmdown)
    }

    var body: some View {
        Form {
            PlanEditOutcomeSection(outcome: outcome, errorMessage: errorMessage)

            Section("Suggested days") {
                ForEach(Self.days, id: \.self) { day in
                    Toggle(day.capitalized, isOn: dayBinding(day))
                }
            }

            Section("Equipment") {
                TextField("Default bar", text: $barWeight)
                    .keyboardType(.decimalPad)
                TextField("Plates per side", text: $plates)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Dumbbells", text: $dumbbells)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Rounding", selection: $rounding) {
                    Text("Nearest").tag(RoundingMode.nearest)
                    Text("Down").tag(RoundingMode.down)
                }
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
        }
    }

    private func dayBinding(_ day: String) -> Binding<Bool> {
        Binding(
            get: { selectedDays.contains(day) },
            set: { enabled in
                if enabled { selectedDays.insert(day) } else { selectedDays.remove(day) }
            }
        )
    }

    private func save() {
        let equipment = EquipmentProfile(
            bars: parsedSingle(barWeight).map { ["default": $0] } ?? [:],
            platePairs: parsedList(plates),
            dumbbells: parsedList(dumbbells),
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
                )
            )
        )
        apply(edit, message: "Update plan settings")
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

    private func parsedSingle(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func parsedList(_ text: String) -> [Double] {
        text.split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }
            .compactMap { Double(String($0).replacingOccurrences(of: ",", with: ".")) }
    }

    private static func formatNumber(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded == value { return String(Int(rounded)) }
        return String(value)
    }

    private static let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

private struct SessionExercisesEditor: View {
    let title: String
    let systemImage: String
    @Binding var exercises: [SessionExercise]

    var body: some View {
        Section {
            if exercises.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            }
            ForEach(exercises.indices, id: \.self) { index in
                SessionExerciseRow(exercise: $exercises[index])
            }
            .onDelete { offsets in
                exercises.remove(atOffsets: offsets)
            }

            Button {
                exercises.append(SessionExercise(exercise: "", sets: 1, reps: title == "Warmdown" ? 60 : 10))
            } label: {
                Label("Add \(title.lowercased()) exercise", systemImage: "plus.circle")
            }
        } header: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct SessionExerciseRow: View {
    @Binding var exercise: SessionExercise

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Exercise", text: $exercise.exercise)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Stepper("\(exercise.sets) sets", value: $exercise.sets, in: 1...20)
                Stepper("\(exercise.reps) reps", value: $exercise.reps, in: 0...999)
            }
            TextField("Load or note", text: loadOrNoteBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
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

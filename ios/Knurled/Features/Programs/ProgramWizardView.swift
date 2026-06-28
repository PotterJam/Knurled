import SwiftUI

/// Guided program authoring. Built-ins stay engine-described; "No template" emits the bounded
/// ADR-0003 document consumed by the generic Rust evaluator.
struct ProgramWizardView: View {
    let repo: ActiveRepo

    private enum Source: String, CaseIterable, Identifiable {
        case builtIn = "Built-in"
        case custom = "No template"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .builtIn
    @State private var template: StarterTemplate?
    @State private var name = ""
    @State private var units: Units = .kg
    @State private var values: [String: String] = [:]
    @State private var exercise = "squat"
    @State private var setCount = 3
    @State private var reps = 5
    @State private var usesCycle = true
    @State private var hasAmrap = true
    @State private var increment = 2.5
    @State private var deloadPercent = 60
    @State private var restSeconds = 120
    @State private var days: Set<String> = ["mon", "wed", "fri"]
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var spec: InitialTrainingNumbers.Spec { InitialTrainingNumbers.spec(for: template) }
    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if source == .builtIn {
            return template != nil && InitialTrainingNumbers.isComplete(values: values, for: spec)
        }
        return !exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && InitialTrainingNumbers.normalizedPositiveNumber(values[exercise, default: ""]) != nil
    }

    var body: some View {
        Form {
            Section("Starting point") {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if source == .builtIn {
                    Picker("Template", selection: $template) {
                        ForEach(app.starterTemplates) { Text($0.title).tag(Optional($0)) }
                    }
                }
                TextField("Program name", text: $name)
            }

            if source == .builtIn {
                InitialTrainingNumbersEditor(spec: spec, units: $units, values: $values)
            } else {
                Section("Set scheme") {
                    TextField("Exercise", text: $exercise)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Units", selection: $units) {
                        Text("kg").tag(Units.kg)
                        Text("lb").tag(Units.lb)
                    }
                    TextField("Starting load", text: customStartBinding)
                        .keyboardType(.decimalPad)
                    Stepper("Sets: \(setCount)", value: $setCount, in: 1...10)
                    Stepper("Reps: \(reps)", value: $reps, in: 1...20)
                    Toggle("AMRAP top set", isOn: $hasAmrap)
                }
                Section("Progression") {
                    Toggle("Wave + deload", isOn: $usesCycle)
                    Stepper("Increase: \(increment.formatted()) \(units.rawValue)", value: $increment, in: 0.5...20, step: 0.5)
                    if usesCycle {
                        Stepper("Deload intensity: \(deloadPercent)%", value: $deloadPercent, in: 40...90, step: 5)
                    }
                }
            }

            Section("Schedule and rest") {
                HStack {
                    ForEach(Self.weekdays, id: \.self) { day in
                        Button(day.prefix(1).uppercased()) {
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(days.contains(day) ? .accentColor : .secondary)
                    }
                }
                Stepper("Rest: \(restSeconds / 60)m \(restSeconds % 60)s", value: $restSeconds, in: 15...600, step: 15)
            }

            Section("Review") {
                LabeledContent("Program", value: name)
                LabeledContent("Source", value: source.rawValue)
                LabeledContent("Days", value: selectedDays.map(\.capitalized).joined(separator: ", "))
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Program wizard")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { save() }.disabled(isSaving || !canSave)
            }
        }
        .task {
            await app.loadStarterTemplates()
            if template == nil {
                template = app.starterTemplates.first
                name = template?.title ?? "My Program"
                values = InitialTrainingNumbers.emptyValues(for: spec)
                await loadSuggestions()
            }
        }
        .onChange(of: template) { _, template in
            if source == .builtIn { name = template?.title ?? name }
            values = InitialTrainingNumbers.emptyValues(for: spec)
            Task { await loadSuggestions() }
        }
        .onChange(of: source) { _, source in
            if source == .custom {
                name = "My Program"
                if values[exercise] == nil { values[exercise] = units == .kg ? "60" : "135" }
            }
        }
    }

    private var customStartBinding: Binding<String> {
        Binding(get: { values[exercise, default: ""] }, set: { values[exercise] = $0 })
    }

    private var selectedDays: [String] { Self.weekdays.filter(days.contains) }

    private func loadSuggestions() async {
        guard source == .builtIn, let template else { return }
        if let suggestions = try? await app.engine.suggestInitialNumbers(
            dir: repo.url,
            request: InitialNumberSuggestionRequest(template: template.reference, units: units)
        ) {
            for (exercise, value) in suggestions.values { values[exercise] = value }
        }
    }

    private func save() {
        let request: AddProgramRequest
        if source == .custom {
            guard let start = InitialTrainingNumbers.normalizedPositiveNumber(values[exercise, default: ""]) else { return }
            request = AddProgramRequest(
                displayName: name,
                template: "custom",
                units: units,
                initialNumbers: [LiveItem.normalized(exercise): "\(start)\(units.rawValue)"],
                suggestedDays: selectedDays,
                customTemplate: customDocument,
                rest: RestPolicy(defaultSeconds: restSeconds)
            )
        } else {
            guard let template else { return }
            let numbers = Dictionary(uniqueKeysWithValues: spec.fields.compactMap { field -> (String, String)? in
                guard let value = InitialTrainingNumbers.normalizedPositiveNumber(values[field.exercise, default: ""]) else { return nil }
                return (field.exercise, "\(value)\(units.rawValue)")
            })
            request = AddProgramRequest(
                displayName: name,
                template: template.reference,
                units: units,
                initialNumbers: numbers,
                suggestedDays: selectedDays,
                rest: RestPolicy(defaultSeconds: restSeconds)
            )
        }
        isSaving = true
        Task {
            do { _ = try await app.addProgram(request, in: repo); dismiss() }
            catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }

    private var customDocument: String {
        let normalized = LiveItem.normalized(exercise)
        let amrap = hasAmrap ? " amrap=#true" : ""
        let deload = usesCycle
            ? "\n    stage \"deload\" { set count=\(setCount) reps=\(reps) intensity=\(deloadPercent) }"
            : ""
        let advance = usesCycle ? "; advance_stage" : ""
        let cycleEnd = usesCycle ? "\n    on cycle_end { reset_stage; advance_cycle }" : ""
        return """
        template "\(name)" version="1.0.0" {
          rotation day
          rest \(restSeconds)
          session day { item "\(normalized).main" slot="day.\(normalized)" }
          lane "\(normalized).main" exercise="\(normalized)" basis="working_weight" sequence="\(usesCycle ? "cycle" : "none")" {
            stage "work" { set count=\(setCount) reps=\(reps) intensity=100\(amrap) }\(deload)
            on pass { increase_load by=\(increment)\(advance) }\(cycleEnd)
          }
        }
        """
    }

    private static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

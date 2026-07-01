import SwiftUI

/// Guided program authoring. Built-ins stay engine-described and configure just their numbers;
/// the custom path opens the structured `DslTemplate` editor (Phase 6), and built-ins can be
/// forked into that same editor to customise. No `.fitspec` text is string-built in Swift.
struct ProgramWizardView: View {
    let repo: ActiveRepo

    private enum Source: String, CaseIterable, Identifiable {
        case builtIn = "Built-in"
        case custom = "Custom"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .builtIn
    @State private var template: StarterTemplate?
    @State private var name = ""
    @State private var units: Units = .kg
    @State private var values: [String: String] = [:]
    @State private var restSeconds = 120
    @State private var days: Set<String> = ["mon", "wed", "fri"]
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var spec: InitialTrainingNumbers.Spec { InitialTrainingNumbers.spec(for: template) }
    private var canSave: Bool {
        guard source == .builtIn else { return false }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return template != nil && InitialTrainingNumbers.isComplete(values: values, for: spec)
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
                    TextField("Program name", text: $name)
                }
            }

            if source == .builtIn {
                InitialTrainingNumbersEditor(spec: spec, units: $units, values: $values)

                Section("Schedule and rest") {
                    weekdayRow
                    Stepper("Rest: \(restSeconds / 60)m \(restSeconds % 60)s", value: $restSeconds, in: 15...600, step: 15)
                }

                Section {
                    if let template {
                        NavigationLink {
                            ForkProgramLoader(
                                repo: repo,
                                reference: template.reference,
                                name: name.isEmpty ? template.title : name,
                                units: units
                            )
                        } label: {
                            Label("Customise this template", systemImage: "slider.horizontal.3")
                        }
                    }
                } footer: {
                    Text("Start from a copy of this template and change its exercises, days, or how weights progress.")
                }

                Section("Review") {
                    LabeledContent("Program", value: name)
                    LabeledContent("Days", value: selectedDays.map(\.capitalized).joined(separator: ", "))
                }
            } else {
                Section {
                    NavigationLink {
                        ProgramAuthoringView(
                            repo: repo,
                            model: .blank(engine: app.engine, name: "My Program", units: units)
                        )
                    } label: {
                        Label("Open structured editor", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("Build your own program from scratch, with live checks and a preview of the first workout.")
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add program")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if source == .builtIn {
                    Button("Create") { save() }.disabled(isSaving || !canSave)
                }
            }
        }
        .task {
            await app.loadStarterTemplates()
            await app.loadExerciseCatalog()
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
    }

    private var weekdayRow: some View {
        HStack {
            ForEach(Self.weekdays, id: \.self) { day in
                Button(day.prefix(1).uppercased()) {
                    if days.contains(day) { days.remove(day) } else { days.insert(day) }
                }
                .buttonStyle(.bordered)
                .tint(days.contains(day) ? .accentColor : .secondary)
            }
        }
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
        guard let template else { return }
        let numbers = Dictionary(uniqueKeysWithValues: spec.fields.compactMap { field -> (String, String)? in
            guard let value = InitialTrainingNumbers.normalizedPositiveNumber(values[field.exercise, default: ""]) else { return nil }
            return (field.exercise, "\(value)\(units.rawValue)")
        })
        let request = AddProgramRequest(
            displayName: name,
            template: template.reference,
            units: units,
            initialNumbers: numbers,
            suggestedDays: selectedDays,
            rest: RestPolicy(defaultSeconds: restSeconds)
        )
        isSaving = true
        Task {
            do { _ = try await app.addProgram(request, in: repo); dismiss() }
            catch { errorMessage = error.localizedDescription }
            isSaving = false
        }
    }

    private static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}

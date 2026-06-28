import SwiftUI

struct ProgramBankView: View {
    let repo: ActiveRepo

    @Environment(AppModel.self) private var app
    @State private var errorMessage: String?
    @State private var busySlug: String?

    var body: some View {
        List {
            if let active = repo.programs.first(where: \.isActive) {
                Section("Active") { row(active) }
            }
            Section("Program bank") {
                ForEach(repo.programs.filter { !$0.isActive }) { program in
                    row(program)
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(program) }
                        }
                }
            }
            Section {
                NavigationLink {
                    ProgramWizardView(repo: repo)
                } label: {
                    Label("Create program", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Programs")
        .alert("Program change failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func row(_ program: ProgramSummary) -> some View {
        Button {
            guard !program.isActive else { return }
            activate(program)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(program.displayName).foregroundStyle(.primary)
                    Text(program.template).font(.caption).foregroundStyle(.secondary)
                    if let next = program.nextSession {
                        Text("Next: \(next.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busySlug == program.slug {
                    ProgressView()
                } else if program.isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                } else if program.validity != .valid {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busySlug != nil)
    }

    private func activate(_ program: ProgramSummary) {
        busySlug = program.slug
        Task {
            do { _ = try await app.setActiveProgram(program.slug, in: repo) }
            catch { errorMessage = error.localizedDescription }
            busySlug = nil
        }
    }

    private func delete(_ program: ProgramSummary) {
        busySlug = program.slug
        Task {
            do { _ = try await app.deleteProgram(program.slug, in: repo) }
            catch { errorMessage = error.localizedDescription }
            busySlug = nil
        }
    }
}

private struct ProgramCreateView: View {
    let repo: ActiveRepo

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: StarterTemplate?
    @State private var units: Units = .kg
    @State private var values: [String: String] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var spec: InitialTrainingNumbers.Spec { InitialTrainingNumbers.spec(for: template) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && template != nil
            && InitialTrainingNumbers.isComplete(values: values, for: spec)
    }

    var body: some View {
        Form {
            Section("Program") {
                TextField("Name", text: $name)
                Picker("Template", selection: $template) {
                    ForEach(app.starterTemplates) { template in
                        Text(template.title).tag(Optional(template))
                    }
                }
            }
            InitialTrainingNumbersEditor(spec: spec, units: $units, values: $values)
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Create program")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { save() }.disabled(isSaving || !canSave)
            }
        }
        .task {
            await app.loadStarterTemplates()
            if template == nil {
                template = app.starterTemplates.first
                name = template?.title ?? ""
                values = InitialTrainingNumbers.emptyValues(for: spec)
                await loadSuggestions()
            }
        }
        .onChange(of: template) { _, selected in
            if name.isEmpty { name = selected?.title ?? "" }
            values = InitialTrainingNumbers.emptyValues(for: spec)
            Task { await loadSuggestions() }
        }
        .onChange(of: units) { _, _ in
            values = InitialTrainingNumbers.emptyValues(for: spec)
            Task { await loadSuggestions() }
        }
    }

    private func loadSuggestions() async {
        guard let template else { return }
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
            guard let value = InitialTrainingNumbers.normalizedPositiveNumber(values[field.exercise, default: ""])
            else { return nil }
            return (field.exercise, "\(value)\(units.rawValue)")
        })
        isSaving = true
        Task {
            do {
                _ = try await app.addProgram(
                    AddProgramRequest(
                        displayName: name,
                        template: template.reference,
                        units: units,
                        initialNumbers: numbers,
                        suggestedDays: []
                    ),
                    in: repo
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

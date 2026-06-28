import SwiftUI

struct AddExerciseSheet: View {
    let repo: ActiveRepo
    let catalog: [ExerciseCatalogEntry]
    var onAdd: (String, String?, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var search = ""
    @State private var selected: ExerciseCatalogEntry?
    @State private var loadText = ""
    @State private var setCount = 3
    @State private var reps = 10

    private var repoExercises: [ExerciseCatalogEntry] {
        (repo.plan?.exercises ?? [:])
            .map { id, exercise in
                ExerciseCatalogEntry(
                    id: id,
                    label: exercise.label,
                    pattern: exercise.pattern ?? "custom",
                    implement: exercise.implement,
                    custom: true
                )
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var allExercises: [ExerciseCatalogEntry] {
        var seen = Set<String>()
        return (repoExercises + catalog).filter { entry in
            seen.insert(entry.id).inserted
        }
    }

    private var normalizedSearch: String {
        LiveItem.normalized(search)
    }

    private var matches: [ExerciseCatalogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(allExercises.prefix(24)) }
        return allExercises
            .filter {
                $0.label.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(normalizedSearch)
            }
            .prefix(24)
            .map { $0 }
    }

    private var exactMatch: ExerciseCatalogEntry? {
        allExercises.first {
            $0.id == normalizedSearch || $0.label.caseInsensitiveCompare(search) == .orderedSame
        }
    }

    private var canAdd: Bool {
        selected != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unit: String {
        repo.plan?.plan.units.rawValue ?? "kg"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Search or create", text: $search)
                        .textInputAutocapitalization(.words)
                    ForEach(matches) { exercise in
                        Button {
                            selected = exercise
                            search = exercise.label
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.label)
                                    Text(exercise.pattern)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == exercise.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if exactMatch == nil && !normalizedSearch.isEmpty {
                        Button {
                            selected = ExerciseCatalogEntry(
                                id: normalizedSearch,
                                label: Self.titleCase(normalizedSearch),
                                pattern: "custom",
                                custom: true
                            )
                        } label: {
                            Label("Create \"\(Self.titleCase(normalizedSearch))\"", systemImage: "plus.circle")
                        }
                    }
                }

                Section("Set scheme") {
                    HStack {
                        Text("Load")
                        Spacer()
                        TextField("optional", text: $loadText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                        Text(unit)
                            .foregroundStyle(.secondary)
                    }
                    pickerRow(title: setCount == 1 ? "1 set" : "\(setCount) sets") {
                        HorizontalNumberPicker(value: $setCount, range: 1...20)
                    }
                    pickerRow(title: reps == 1 ? "1 rep" : "\(reps) reps") {
                        HorizontalNumberPicker(value: $reps, range: 0...99)
                    }
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        add()
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func pickerRow(title: String, @ViewBuilder picker: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            picker()
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func add() {
        let exercise = selected ?? ExerciseCatalogEntry(
            id: normalizedSearch,
            label: Self.titleCase(normalizedSearch),
            pattern: "custom",
            custom: true
        )
        if exercise.custom || exactMatch == nil {
            Task {
                _ = try? await app.applyPlanEdit(
                    .quick(QuickPlanEdit(
                        suggestedDays: nil,
                        equipment: nil,
                        customExercise: CustomExerciseEdit(
                            id: exercise.id,
                            label: exercise.label,
                            pattern: exercise.pattern,
                            implement: exercise.implement
                        ),
                        accessory: nil,
                        sessionExercises: nil,
                        rest: nil
                    )),
                    in: repo,
                    message: "Add custom exercise"
                )
            }
        }
        let trimmedLoad = loadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let load: String?
        if trimmedLoad.isEmpty {
            load = nil
        } else if Double(trimmedLoad) != nil {
            load = "\(trimmedLoad)\(unit)"
        } else {
            load = trimmedLoad
        }
        onAdd(exercise.id, load, setCount, reps)
    }

    private static func titleCase(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

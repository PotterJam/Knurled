import SwiftUI

struct CustomExercisesView: View {
    let repo: ActiveRepo
    @State private var editing: EditableCustomExercise?

    private var exercises: [EditableCustomExercise] {
        (repo.plan?.exercises ?? [:])
            .map { id, exercise in
                EditableCustomExercise(
                    id: id,
                    label: exercise.label,
                    pattern: exercise.pattern ?? "custom",
                    implement: exercise.implement ?? "custom"
                )
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        List {
            if exercises.isEmpty {
                ContentUnavailableView {
                    Label("No Custom Exercises", systemImage: "figure.strengthtraining.traditional")
                } description: {
                    Text("Exercises you create during a workout will appear here.")
                }
            } else {
                ForEach(exercises) { exercise in
                    Button {
                        editing = exercise
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise.label)
                                Text(exercise.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(exercise.pattern)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Custom Exercises")
        .sheet(item: $editing) { exercise in
            EditCustomExerciseSheet(repo: repo, exercise: exercise)
        }
    }
}

struct EditableCustomExercise: Identifiable, Hashable {
    var id: String
    var label: String
    var pattern: String
    var implement: String
}

private struct EditCustomExerciseSheet: View {
    let repo: ActiveRepo
    let exercise: EditableCustomExercise

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var label: String
    @State private var pattern: String
    @State private var implement: String

    init(repo: ActiveRepo, exercise: EditableCustomExercise) {
        self.repo = repo
        self.exercise = exercise
        _label = State(initialValue: exercise.label)
        _pattern = State(initialValue: exercise.pattern)
        _implement = State(initialValue: exercise.implement)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Label", text: $label)
                    TextField("Pattern", text: $pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Implement", text: $implement)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(exercise.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let entry = ExerciseCatalogEntry(
            id: exercise.id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? exercise.label : label,
            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "custom" : LiveItem.normalized(pattern),
            implement: implement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "custom" : LiveItem.normalized(implement),
            custom: true
        )
        Task {
            _ = try? await app.applyPlanEdit(
                .quick(QuickPlanEdit(
                    suggestedDays: nil,
                    equipment: nil,
                    customExercise: CustomExerciseEdit(
                        id: entry.id,
                        label: entry.label,
                        pattern: entry.pattern,
                        implement: entry.implement
                    ),
                    accessory: nil,
                    sessionExercises: nil,
                    rest: nil
                )),
                in: repo,
                message: "Update custom exercise"
            )
        }
    }
}

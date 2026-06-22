import SwiftUI

struct SetDetailSheet: View {
    let set: LiveSet
    @Environment(\.dismiss) private var dismiss
    @State private var loadText: String

    init(set: LiveSet) {
        self.set = set
        _loadText = State(initialValue: set.load ?? "")
    }

    var body: some View {
        @Bindable var set = set
        NavigationStack {
            Form {
                Section("Prescribed") {
                    let load = set.prescribed.load ?? "bodyweight"
                    Text("\(load) × \(set.prescribed.targetReps)\(set.prescribed.amrap ? "+" : "")")
                        .foregroundStyle(.secondary)
                }
                Section("Actual") {
                    TextField("Load", text: $loadText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("\(set.reps) reps", value: $set.reps, in: 0...99)
                }
            }
            .navigationTitle("Set \(set.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Set") {
                        let trimmed = loadText.trimmingCharacters(in: .whitespaces)
                        set.load = trimmed.isEmpty ? nil : trimmed
                        set.logged = true
                        dismiss()
                    }
                }
            }
        }
    }
}

import SwiftUI

struct SetDetailSheet: View {
    let set: LiveSet
    @Environment(\.dismiss) private var dismiss
    @State private var loadText: String
    @State private var rpe: Double?

    init(set: LiveSet) {
        self.set = set
        _loadText = State(initialValue: set.load ?? "")
        _rpe = State(initialValue: set.rpe)
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
                    rpeControl
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
                        set.rpe = rpe
                        set.logged = true
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder private var rpeControl: some View {
        if let value = rpe {
            HStack {
                Text("RPE")
                Spacer()
                Button {
                    rpe = max(1, value - 0.5)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                Text(LiveSet.formatRPE(value))
                    .font(.body.monospacedDigit().weight(.medium))
                    .frame(minWidth: 34)
                Button {
                    rpe = min(10, value + 0.5)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                Button {
                    rpe = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove RPE")
            }
        } else {
            Button {
                rpe = 8
            } label: {
                Label("Add RPE", systemImage: "gauge.medium")
            }
        }
    }
}

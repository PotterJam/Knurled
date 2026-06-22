import SwiftUI

struct SwapExerciseSheet: View {
    let live: LiveItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        live.clearSwap()
                        dismiss()
                    } label: {
                        optionRow(
                            name: live.prescribedExerciseName,
                            detail: "Prescribed",
                            selected: !live.isSwapped
                        )
                    }
                }

                if let options = live.options {
                    Section("Approved alternatives") {
                        ForEach(options.alternatives) { alternative in
                            Button {
                                live.swap(to: alternative)
                                dismiss()
                            } label: {
                                optionRow(
                                    name: alternative.label,
                                    detail: policyText(alternative.policy),
                                    selected: live.performedExercise == alternative.exercise
                                )
                            }
                        }
                    }
                }

                Section {
                    Text("Swaps are recorded with your log. Tracking-only swaps keep your prescribed progression unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Swap Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func optionRow(name: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }

    private func policyText(_ policy: SwapPolicy) -> String {
        switch policy {
        case .trackingOnly: "Tracking only"
        case .progressionEquivalent: "Counts toward progression"
        }
    }
}

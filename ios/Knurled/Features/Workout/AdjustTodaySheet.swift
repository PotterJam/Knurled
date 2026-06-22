import SwiftUI

struct AdjustTodaySheet: View {
    let live: LiveItem
    @Environment(\.dismiss) private var dismiss

    @State private var loadText: String
    @State private var scope: AdjustScope = .remaining
    @State private var reason: String = ""

    init(live: LiveItem) {
        self.live = live
        _loadText = State(initialValue: live.todayLoad ?? live.prescribedLoad ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prescribed load") {
                    Text(live.prescribedLoad ?? "bodyweight")
                        .foregroundStyle(.secondary)
                }
                Section("Use today") {
                    TextField("e.g. 77.5kg", text: $loadText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Apply to") {
                    Picker("Apply to", selection: $scope) {
                        ForEach(AdjustScope.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Reason (optional)") {
                    TextField("Not feeling good / tired / sore", text: $reason)
                }
                Section {
                    Text("Adjusting today logs what happened. It does not change your future plan — the prescribed load repeats next time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Adjust \(live.item.display.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let trimmed = loadText.trimmingCharacters(in: .whitespaces)
                        let firstUnlogged = live.sets.first { !$0.logged }?.id ?? 1
                        live.adjust(
                            load: trimmed.isEmpty ? nil : trimmed,
                            scope: scope,
                            from: firstUnlogged
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}

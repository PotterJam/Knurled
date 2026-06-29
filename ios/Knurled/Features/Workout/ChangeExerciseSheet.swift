import SwiftUI

struct ChangeExerciseSheet: View {
    let live: LiveItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedExercise: String
    @State private var loadValue: Double
    @State private var loadDraft: LoadEditDraft
    @State private var isEditingLoad = false
    @State private var loadFieldFrame = CGRect.zero
    @State private var loadUnit: Units
    @State private var scope: AdjustScope = .remaining
    @FocusState private var isLoadFieldFocused: Bool

    init(live: LiveItem, onChanged: @escaping () -> Void) {
        self.live = live
        self.onChanged = onChanged
        let parsed = LoadControl.parse(live.currentLoad, defaultUnit: live.units)
        let unit = parsed?.unit ?? live.units
        let initialValue = parsed?.value
            ?? LoadControl.defaultValue(for: live.performedExercise ?? live.item.exercise, unit: unit)
        _selectedExercise = State(initialValue: live.performedExercise ?? live.item.exercise)
        _loadValue = State(initialValue: initialValue)
        _loadDraft = State(initialValue: LoadEditDraft(
            baselineText: LoadControl.format(initialValue, unit: unit)
        ))
        _loadUnit = State(initialValue: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                if live.canSwap {
                    Section("Exercise") {
                        Picker("Exercise", selection: $selectedExercise) {
                            Text(live.prescribedExerciseName).tag(live.item.exercise)
                            ForEach(live.options?.alternatives ?? []) { alternative in
                                Text(alternative.label).tag(alternative.exercise)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                Section("Today’s load") {
                    if isEditingLoad {
                        loadEditorRow
                    } else {
                        Button {
                            beginLoadEditing()
                        } label: {
                            HStack {
                                Text(LoadControl.format(loadValue, unit: loadUnit))
                                    .font(.title3.monospacedDigit().weight(.semibold))
                                Spacer()
                                Text(live.prescribedLoad.map { "Prescribed \($0)" } ?? "Set base load")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
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

                Section {
                    Text("Changes are recorded with this workout. Tracking-only swaps keep your prescribed progression unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .coordinateSpace(name: "changeExerciseSheet")
            .scrollDismissesKeyboard(.interactively)
            // Only listen for an outside tap while the load field is up. Left always-on, this
            // form-wide tap recogniser swallowed taps on the exercise Picker rows, so you couldn't
            // actually select the exercise to change to. `including: .subviews` disables it
            // otherwise, letting the Picker (and other controls) receive their taps normally.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("changeExerciseSheet")).onEnded { value in
                    guard isLoadFieldFocused, !loadFieldFrame.contains(value.location) else { return }
                    endLoadEditing()
                },
                including: isLoadFieldFocused ? .all : .subviews
            )
            .navigationTitle("Change \(live.item.display.title)")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedExercise) { _, exercise in
                let value = LoadControl.defaultValue(for: exercise, unit: loadUnit)
                loadValue = value
                loadDraft = LoadEditDraft(baselineText: LoadControl.format(value, unit: loadUnit))
            }
            .onChange(of: loadDraft.destinationText) { _, _ in applyLoadText() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { endLoadEditing() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var loadEditorRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(loadDraft.baselineText)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("New", text: $loadDraft.destinationText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.title.monospacedDigit().weight(.semibold))
                .frame(width: 120)
                .focused($isLoadFieldFocused)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("changeExerciseSheet"))
                } action: { frame in
                    loadFieldFrame = frame
                }

            Text(loadUnit.rawValue)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .task { isLoadFieldFocused = true }
    }

    private func beginLoadEditing() {
        loadDraft = LoadEditDraft(baselineText: LoadControl.format(loadValue, unit: loadUnit))
        isEditingLoad = true
        isLoadFieldFocused = true
    }

    private func endLoadEditing() {
        isLoadFieldFocused = false
        isEditingLoad = false
    }

    private func applyLoadText() {
        guard let value = Double(loadDraft.destinationText.trimmingCharacters(in: .whitespaces)) else { return }
        loadValue = max(0, value)
    }

    private func apply() {
        if selectedExercise == live.item.exercise {
            live.clearSwap()
        } else if let alternative = live.options?.alternatives.first(where: { $0.exercise == selectedExercise }) {
            live.swap(to: alternative)
        }

        let firstUnlogged = live.sets.first { !$0.logged }?.id ?? 1
        live.adjust(
            load: LoadControl.format(loadValue, unit: loadUnit),
            scope: scope,
            from: firstUnlogged
        )
        onChanged()
    }
}

struct LoadEditDraft {
    let baselineText: String
    let seedsWholeExercise: Bool
    var destinationText = ""

    init(baselineText: String, seedsWholeExercise: Bool = false) {
        self.baselineText = baselineText
        self.seedsWholeExercise = seedsWholeExercise
    }

    @MainActor
    func applyDestination(to set: LiveSet, in item: LiveItem, units: Units) {
        guard let value = Double(destinationText.trimmingCharacters(in: .whitespaces)) else { return }
        let formatted = LoadControl.format(max(0, value), unit: units)
        if seedsWholeExercise {
            item.adjust(load: formatted, scope: .wholeExercise, from: set.id)
        } else {
            set.load = formatted
        }
    }
}

@MainActor
enum LoadControl {
    static func parse(_ load: String?, defaultUnit: Units) -> (value: Double, unit: Units)? {
        guard let load else { return nil }
        let trimmed = load.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let unit: Units
        let numberPart: Substring
        if trimmed.hasSuffix("kg") {
            unit = .kg
            numberPart = trimmed.dropLast(2)
        } else if trimmed.hasSuffix("lb") {
            unit = .lb
            numberPart = trimmed.dropLast(2)
        } else {
            unit = defaultUnit
            numberPart = Substring(trimmed)
        }

        guard let value = Double(numberPart.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (value, unit)
    }

    static func defaultValue(for exercise: String, unit: Units) -> Double {
        if LiveItem.legacyBodyweightExercise(exercise) {
            return 0
        }

        return switch unit {
        case .kg: 20
        case .lb: 45
        }
    }

    static func format(_ value: Double, unit: Units) -> String {
        let number = numberText(max(0, value))
        return "\(number)\(unit.rawValue)"
    }

    static func numberText(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

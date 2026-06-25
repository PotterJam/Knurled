import SwiftUI

struct ChangeExerciseSheet: View {
    let live: LiveItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedExercise: String
    @State private var loadValue: Double
    @State private var loadUnit: Units
    @State private var scope: AdjustScope = .remaining

    init(live: LiveItem, onChanged: @escaping () -> Void) {
        self.live = live
        self.onChanged = onChanged
        let parsed = LoadControl.parse(live.currentLoad, defaultUnit: live.units)
        let unit = parsed?.unit ?? live.units
        _selectedExercise = State(initialValue: live.performedExercise ?? live.item.exercise)
        _loadValue = State(
            initialValue: parsed?.value
                ?? LoadControl.defaultValue(for: live.performedExercise ?? live.item.exercise, unit: unit)
        )
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
                    HStack {
                        Text(LoadControl.format(loadValue, unit: loadUnit))
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Spacer()
                        Text(live.prescribedLoad.map { "Prescribed \($0)" } ?? "Set base load")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $loadValue,
                        in: LoadControl.range(containing: loadValue, unit: loadUnit),
                        step: LoadControl.step(for: loadUnit)
                    )
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
            .navigationTitle("Change \(live.item.display.title)")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedExercise) { _, exercise in
                loadValue = LoadControl.defaultValue(for: exercise, unit: loadUnit)
            }
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
            }
        }
        .presentationDetents([.medium, .large])
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

private enum LoadControl {
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
        if isBodyweightExercise(exercise) {
            return 0
        }

        return switch unit {
        case .kg: 20
        case .lb: 45
        }
    }

    static func isBodyweightExercise(_ exercise: String) -> Bool {
        let normalized = exercise
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        return normalized.contains("pull_up")
            || normalized.contains("pullup")
            || normalized.contains("chin_up")
            || normalized.contains("chinup")
    }

    static func step(for unit: Units) -> Double {
        switch unit {
        case .kg: 2.5
        case .lb: 5
        }
    }

    static func range(containing value: Double, unit: Units) -> ClosedRange<Double> {
        let baseline = switch unit {
        case .kg: 200.0
        case .lb: 500.0
        }
        return 0...max(baseline, value + 100)
    }

    static func format(_ value: Double, unit: Units) -> String {
        let rounded = (value / step(for: unit)).rounded() * step(for: unit)
        let number = if rounded.rounded() == rounded {
            String(Int(rounded))
        } else {
            String(format: "%.1f", rounded)
        }
        return "\(number)\(unit.rawValue)"
    }
}

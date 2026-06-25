import Foundation
import SwiftUI

struct InitialTrainingNumbers: Sendable, Hashable {
    enum Block: Sendable, Hashable {
        case starts
        case trainingMaxes

        var planBlockName: String {
            switch self {
            case .starts: return "starts"
            case .trainingMaxes: return "training_maxes"
            }
        }
    }

    struct Field: Identifiable, Sendable, Hashable {
        let exercise: String
        let title: String

        var id: String { exercise }
    }

    struct Spec: Sendable, Hashable {
        let block: Block
        let title: String
        let help: String
        let fields: [Field]
    }

    let spec: Spec
    let units: Units
    let values: [String: String]

    func planEntries() throws -> [(exercise: String, load: String)] {
        try spec.fields.map { field in
            let raw = values[field.exercise, default: ""]
            guard let number = Self.normalizedPositiveNumber(raw) else {
                throw GitHubError.badResponse("Enter a positive number for \(field.title).")
            }
            return (field.exercise, "\(number)\(units.rawValue)")
        }
    }

    static func spec(for template: StarterTemplate?) -> Spec {
        let templateID = template?.reference.split(separator: "@").first.map(String.init) ?? ""
        if templateID.starts(with: "531.") {
            return Spec(
                block: .trainingMaxes,
                title: "Training maxes",
                help: "Use the conservative maxes this program should calculate from.",
                fields: mainFields(order: ["squat", "bench", "deadlift", "press"])
            )
        }

        if templateID.starts(with: "starting-strength.") {
            var exercises = ["squat", "bench", "press", "deadlift"]
            if templateID == "starting-strength.phase2" || templateID == "starting-strength.phase3" {
                exercises.append("power_clean")
            }
            return Spec(
                block: .starts,
                title: "Starting loads",
                help: "Use weights you can complete for the first workout.",
                fields: mainFields(order: exercises)
            )
        }

        return Spec(
            block: .starts,
            title: "Starting loads",
            help: "Use the first T1 working weights for the main lifts.",
            fields: mainFields(order: ["squat", "bench", "press", "deadlift"])
        )
    }

    static func emptyValues(for spec: Spec) -> [String: String] {
        Dictionary(uniqueKeysWithValues: spec.fields.map { ($0.exercise, "") })
    }

    static func isComplete(values: [String: String], for spec: Spec) -> Bool {
        spec.fields.allSatisfy { normalizedPositiveNumber(values[$0.exercise, default: ""]) != nil }
    }

    static func normalizedPositiveNumber(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed > 0 else { return nil }
        return normalized
    }

    private static func mainFields(order: [String]) -> [Field] {
        order.map { Field(exercise: $0, title: displayName(for: $0)) }
    }

    private static func displayName(for exercise: String) -> String {
        switch exercise {
        case "squat": return "Squat"
        case "bench": return "Bench"
        case "press": return "Press"
        case "deadlift": return "Deadlift"
        case "power_clean": return "Power clean"
        default: return exercise.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct InitialTrainingNumbersEditor: View {
    let spec: InitialTrainingNumbers.Spec
    @Binding var units: Units
    @Binding var values: [String: String]

    var body: some View {
        Section {
            Picker("Units", selection: $units) {
                Text("kg").tag(Units.kg)
                Text("lb").tag(Units.lb)
            }
            .pickerStyle(.segmented)

            ForEach(spec.fields) { field in
                HStack {
                    Text(field.title)
                    Spacer(minLength: 16)
                    TextField("0", text: valueBinding(for: field.exercise))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                    Text(units.rawValue)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }

            Text(spec.help)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(spec.title)
        }
    }

    private func valueBinding(for exercise: String) -> Binding<String> {
        Binding(
            get: { values[exercise, default: ""] },
            set: { values[exercise] = $0 }
        )
    }
}

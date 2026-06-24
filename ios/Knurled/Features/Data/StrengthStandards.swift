import Foundation

/// The "core 4" powerlifting lifts tracked on the Data tab. The raw value is the
/// lane-key prefix used in the engine state/log (e.g. `squat.t1` → `.squat`).
enum CoreLift: String, CaseIterable, Identifiable, Sendable {
    case squat
    case bench
    case deadlift
    case press

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squat: "Squat"
        case .bench: "Bench"
        case .deadlift: "Deadlift"
        case .press: "Press"
        }
    }

    /// Maps a progression-lane string like `"squat.t1"` to its core lift.
    static func from(lane: String) -> CoreLift? {
        let key = lane.split(separator: ".").first.map(String.init) ?? lane
        return CoreLift(rawValue: key)
    }

    /// Maps normalized exercise names from imported history to the core lift
    /// tracked on the Data tab.
    static func from(exercise: String?) -> CoreLift? {
        guard let exercise else { return nil }
        switch normalize(exercise) {
        case "squat", "back_squat", "barbell_squat":
            return .squat
        case "bench", "bench_press", "barbell_bench_press", "flat_bench_press":
            return .bench
        case "deadlift", "barbell_deadlift":
            return .deadlift
        case "press", "overhead_press", "barbell_press", "strict_press", "shoulder_press":
            return .press
        default:
            return nil
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "_")
    }
}

/// Named strength tiers. Numeric `value` doubles as the y-position of the shared
/// level line on the chart, so every lift at "Novice" sits on the same line.
enum StrengthLevel: Int, CaseIterable, Identifiable, Sendable {
    case beginner = 1
    case novice = 2
    case intermediate = 3
    case advanced = 4
    case elite = 5

    var id: Int { rawValue }
    var value: Double { Double(rawValue) }

    var title: String {
        switch self {
        case .beginner: "Beginner"
        case .novice: "Novice"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        case .elite: "Elite"
        }
    }
}

/// Per-sex, per-lift body-weight multiples for each strength level. Approximate
/// general standards (load ÷ body weight), tunable in one place. Flipping `sex`
/// swaps the entire table, which re-maps every lift line on the chart at once.
///
/// Order within each array matches the measured `StrengthLevel` thresholds:
/// `[beginner, novice, intermediate, advanced]`. `Elite` is the next chart
/// tier above the existing top threshold, reached by the same extrapolation
/// logic that already handled values beyond the top standard.
enum StrengthStandards {
    private static let measuredThresholdCount = 4

    private static let table: [Sex: [CoreLift: [Double]]] = [
        .male: [
            .squat:    [1.25, 1.5, 2.25, 2.75],
            .bench:    [0.75, 1.0, 1.5, 2.0],
            .deadlift: [1.5, 1.75, 2.5, 3.0],
            .press:    [0.55, 0.7, 1.0, 1.3],
        ],
        .female: [
            .squat:    [1.0, 1.25, 1.75, 2.25],
            .bench:    [0.5, 0.65, 0.9, 1.2],
            .deadlift: [1.1, 1.4, 2.0, 2.5],
            .press:    [0.35, 0.45, 0.65, 0.9],
        ],
    ]

    static func multiples(for lift: CoreLift, sex: Sex) -> [Double] {
        table[sex]?[lift] ?? []
    }

    /// Maps a strength ratio (e1RM ÷ body weight) onto the shared level axis for a
    /// given lift and sex, using piecewise-linear interpolation between thresholds.
    /// `novice` lands at 1.0, `elite` at 4.0; below novice scales 0→1, above elite
    /// it extrapolates along the last segment's slope.
    static func levelValue(ratio: Double, lift: CoreLift, sex: Sex) -> Double {
        let t = multiples(for: lift, sex: sex)
        guard t.count == measuredThresholdCount, ratio > 0 else { return 0 }

        if ratio <= t[0] { return ratio / t[0] }

        for i in 0..<(t.count - 1) where ratio <= t[i + 1] {
            let frac = (ratio - t[i]) / (t[i + 1] - t[i])
            return Double(i + 1) + frac
        }

        // Above elite: extrapolate along the advanced→elite slope.
        let last = t.count - 1
        let span = t[last] - t[last - 1]
        let slope = span > 0 ? 1.0 / span : 0
        return Double(last + 1) + (ratio - t[last]) * slope
    }
}

/// Estimated one-rep max and load parsing helpers. A true one-rep set is the
/// load itself; higher-rep sets use the Epley formula, `load × (1 + reps/30)`.
enum OneRepMax {
    static func epley(loadKg: Double, reps: Int) -> Double {
        guard reps > 1 else { return loadKg }
        return loadKg * (1.0 + Double(reps) / 30.0)
    }

    /// Parses an engine load string like `"80kg"`, `"45.5lb"`, or `"100"` into
    /// kilograms. A bare number is assumed to be in `defaultUnit`.
    static func kilograms(fromLoad load: String, defaultUnit: Units) -> Double? {
        let trimmed = load.trimmingCharacters(in: .whitespaces).lowercased()
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
        switch unit {
        case .kg: return value
        case .lb: return value * 0.45359237
        }
    }
}

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

/// Per-sex, per-lift strength standards, **body-weight bracketed** to match
/// strengthlevel.com (its standards vary with body weight, which a single
/// load÷body-weight multiple cannot capture — the old approximation is why the
/// chart disagreed with the site). Each row is a body weight (kg) and the 1RM
/// (kg) thresholds at that body weight for
/// `[beginner, novice, intermediate, advanced, elite]`, sampled every 10kg from
/// strengthlevel.com community standards (June 2026) and interpolated in between.
enum StrengthStandards {
    private static let thresholdCount = 5

    private struct Row {
        let bodyWeightKg: Double
        let thresholds: [Double] // [beginner, novice, intermediate, advanced, elite], 1RM kg
    }

    private static let table: [Sex: [CoreLift: [Row]]] = [
        .male: [
            .squat: [
                Row(bodyWeightKg: 50, thresholds: [33, 52, 76, 104, 136]),
                Row(bodyWeightKg: 60, thresholds: [47, 68, 95, 127, 161]),
                Row(bodyWeightKg: 70, thresholds: [59, 83, 113, 147, 184]),
                Row(bodyWeightKg: 80, thresholds: [72, 98, 130, 166, 205]),
                Row(bodyWeightKg: 90, thresholds: [83, 112, 146, 184, 225]),
                Row(bodyWeightKg: 100, thresholds: [95, 125, 160, 201, 243]),
                Row(bodyWeightKg: 110, thresholds: [106, 137, 174, 216, 260]),
                Row(bodyWeightKg: 120, thresholds: [116, 149, 188, 231, 277]),
                Row(bodyWeightKg: 130, thresholds: [126, 160, 201, 245, 292]),
                Row(bodyWeightKg: 140, thresholds: [136, 171, 213, 259, 307]),
            ],
            .bench: [
                Row(bodyWeightKg: 50, thresholds: [24, 38, 57, 79, 103]),
                Row(bodyWeightKg: 60, thresholds: [34, 51, 72, 96, 123]),
                Row(bodyWeightKg: 70, thresholds: [44, 62, 85, 112, 141]),
                Row(bodyWeightKg: 80, thresholds: [53, 74, 98, 127, 157]),
                Row(bodyWeightKg: 90, thresholds: [62, 84, 111, 141, 172]),
                Row(bodyWeightKg: 100, thresholds: [71, 94, 122, 153, 187]),
                Row(bodyWeightKg: 110, thresholds: [80, 104, 133, 166, 200]),
                Row(bodyWeightKg: 120, thresholds: [88, 113, 143, 177, 213]),
                Row(bodyWeightKg: 130, thresholds: [95, 122, 153, 188, 225]),
                Row(bodyWeightKg: 140, thresholds: [103, 130, 163, 199, 236]),
            ],
            .deadlift: [
                Row(bodyWeightKg: 50, thresholds: [44, 65, 93, 125, 160]),
                Row(bodyWeightKg: 60, thresholds: [58, 83, 114, 149, 187]),
                Row(bodyWeightKg: 70, thresholds: [73, 100, 133, 171, 212]),
                Row(bodyWeightKg: 80, thresholds: [86, 116, 151, 192, 235]),
                Row(bodyWeightKg: 90, thresholds: [99, 131, 168, 211, 256]),
                Row(bodyWeightKg: 100, thresholds: [111, 145, 184, 228, 275]),
                Row(bodyWeightKg: 110, thresholds: [123, 158, 199, 245, 293]),
                Row(bodyWeightKg: 120, thresholds: [134, 171, 213, 261, 311]),
                Row(bodyWeightKg: 130, thresholds: [145, 183, 227, 276, 327]),
                Row(bodyWeightKg: 140, thresholds: [155, 194, 240, 290, 342]),
            ],
            .press: [
                Row(bodyWeightKg: 50, thresholds: [15, 25, 38, 53, 71]),
                Row(bodyWeightKg: 60, thresholds: [21, 32, 47, 64, 84]),
                Row(bodyWeightKg: 70, thresholds: [27, 40, 56, 75, 95]),
                Row(bodyWeightKg: 80, thresholds: [33, 47, 64, 84, 106]),
                Row(bodyWeightKg: 90, thresholds: [39, 54, 72, 93, 116]),
                Row(bodyWeightKg: 100, thresholds: [44, 60, 79, 102, 125]),
                Row(bodyWeightKg: 110, thresholds: [49, 66, 86, 109, 134]),
                Row(bodyWeightKg: 120, thresholds: [54, 72, 93, 117, 142]),
                Row(bodyWeightKg: 130, thresholds: [59, 77, 99, 124, 150]),
                Row(bodyWeightKg: 140, thresholds: [64, 83, 105, 131, 157]),
            ],
        ],
        .female: [
            .squat: [
                Row(bodyWeightKg: 40, thresholds: [17, 31, 51, 75, 101]),
                Row(bodyWeightKg: 50, thresholds: [23, 39, 61, 87, 115]),
                Row(bodyWeightKg: 60, thresholds: [29, 47, 70, 97, 128]),
                Row(bodyWeightKg: 70, thresholds: [34, 53, 78, 106, 138]),
                Row(bodyWeightKg: 80, thresholds: [39, 59, 85, 115, 148]),
                Row(bodyWeightKg: 90, thresholds: [44, 65, 91, 123, 157]),
                Row(bodyWeightKg: 100, thresholds: [48, 70, 98, 130, 165]),
                Row(bodyWeightKg: 110, thresholds: [52, 75, 103, 136, 172]),
                Row(bodyWeightKg: 120, thresholds: [56, 80, 109, 143, 179]),
            ],
            .bench: [
                Row(bodyWeightKg: 40, thresholds: [8, 18, 32, 50, 70]),
                Row(bodyWeightKg: 50, thresholds: [12, 24, 40, 59, 82]),
                Row(bodyWeightKg: 60, thresholds: [17, 29, 47, 68, 92]),
                Row(bodyWeightKg: 70, thresholds: [20, 34, 53, 75, 101]),
                Row(bodyWeightKg: 80, thresholds: [24, 39, 59, 82, 109]),
                Row(bodyWeightKg: 90, thresholds: [28, 44, 64, 89, 116]),
                Row(bodyWeightKg: 100, thresholds: [31, 48, 69, 95, 123]),
                Row(bodyWeightKg: 110, thresholds: [34, 52, 74, 100, 129]),
                Row(bodyWeightKg: 120, thresholds: [37, 56, 79, 106, 135]),
            ],
            .deadlift: [
                Row(bodyWeightKg: 40, thresholds: [24, 40, 62, 89, 118]),
                Row(bodyWeightKg: 50, thresholds: [31, 49, 73, 102, 133]),
                Row(bodyWeightKg: 60, thresholds: [37, 57, 83, 113, 146]),
                Row(bodyWeightKg: 70, thresholds: [43, 64, 91, 123, 157]),
                Row(bodyWeightKg: 80, thresholds: [48, 71, 99, 132, 168]),
                Row(bodyWeightKg: 90, thresholds: [53, 77, 106, 140, 177]),
                Row(bodyWeightKg: 100, thresholds: [58, 82, 112, 147, 185]),
                Row(bodyWeightKg: 110, thresholds: [62, 87, 119, 154, 193]),
                Row(bodyWeightKg: 120, thresholds: [66, 92, 124, 161, 200]),
            ],
            .press: [
                Row(bodyWeightKg: 40, thresholds: [7, 14, 23, 35, 48]),
                Row(bodyWeightKg: 50, thresholds: [10, 17, 28, 40, 55]),
                Row(bodyWeightKg: 60, thresholds: [12, 21, 32, 45, 60]),
                Row(bodyWeightKg: 70, thresholds: [15, 24, 35, 50, 65]),
                Row(bodyWeightKg: 80, thresholds: [17, 26, 39, 54, 70]),
                Row(bodyWeightKg: 90, thresholds: [19, 29, 42, 57, 74]),
                Row(bodyWeightKg: 100, thresholds: [21, 31, 45, 61, 78]),
                Row(bodyWeightKg: 110, thresholds: [23, 34, 47, 64, 81]),
                Row(bodyWeightKg: 120, thresholds: [24, 36, 50, 66, 85]),
            ],
        ],
    ]

    /// The five 1RM (kg) thresholds for a lift/sex interpolated to an exact body weight,
    /// clamped to the tabulated range at the extremes.
    static func thresholds(lift: CoreLift, sex: Sex, bodyWeightKg: Double) -> [Double] {
        guard let rows = table[sex]?[lift], let first = rows.first, let last = rows.last else {
            return []
        }
        if bodyWeightKg <= first.bodyWeightKg { return first.thresholds }
        if bodyWeightKg >= last.bodyWeightKg { return last.thresholds }
        for i in 0..<(rows.count - 1) where bodyWeightKg <= rows[i + 1].bodyWeightKg {
            let lo = rows[i], hi = rows[i + 1]
            let frac = (bodyWeightKg - lo.bodyWeightKg) / (hi.bodyWeightKg - lo.bodyWeightKg)
            return zip(lo.thresholds, hi.thresholds).map { $0 + frac * ($1 - $0) }
        }
        return last.thresholds
    }

    /// Maps an estimated 1RM (kg) onto the shared level axis for a lift/sex/body weight.
    /// Beginner→1, novice→2, intermediate→3, advanced→4, elite→5; below beginner scales
    /// 0→1; above elite extrapolates along the advanced→elite slope.
    static func levelValue(e1rmKg: Double, bodyWeightKg: Double, lift: CoreLift, sex: Sex) -> Double {
        let t = thresholds(lift: lift, sex: sex, bodyWeightKg: bodyWeightKg)
        guard t.count == thresholdCount, e1rmKg > 0, bodyWeightKg > 0 else { return 0 }

        if e1rmKg <= t[0] { return t[0] > 0 ? e1rmKg / t[0] : 0 }

        for i in 0..<(t.count - 1) where e1rmKg <= t[i + 1] {
            let span = t[i + 1] - t[i]
            let frac = span > 0 ? (e1rmKg - t[i]) / span : 0
            return Double(i + 1) + frac
        }

        // Above elite: extrapolate along the advanced→elite slope.
        let span = t[4] - t[3]
        let slope = span > 0 ? 1.0 / span : 0
        return Double(thresholdCount) + (e1rmKg - t[4]) * slope
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

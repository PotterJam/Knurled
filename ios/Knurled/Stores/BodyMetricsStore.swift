import Foundation
import Observation

/// Biological sex, used only to pick the strength-standard multiplier table.
/// Standards differ substantially by sex, so this materially shifts where each
/// lift lands relative to the level lines on the Data tab.
enum Sex: String, CaseIterable, Identifiable, Sendable {
    case male
    case female

    var id: String { rawValue }
    var title: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        }
    }
}

/// Holds the user's body weight, preferred body-weight unit, and sex, persisting
/// them across launches. These are **iOS-only** inputs to the strength-level graph
/// — they are never written into the repo or the training log.
@MainActor
@Observable
final class BodyMetricsStore {
    private static let weightKey = "knurled.bodyWeight"
    private static let unitKey = "knurled.bodyWeightUnit"
    private static let sexKey = "knurled.sex"

    private let defaults: UserDefaults

    /// The entered body weight in `unit`. `nil` until the user provides one.
    var bodyWeight: Double? {
        didSet {
            if let bodyWeight {
                defaults.set(bodyWeight, forKey: Self.weightKey)
            } else {
                defaults.removeObject(forKey: Self.weightKey)
            }
        }
    }

    var unit: Units {
        didSet { defaults.set(unit.rawValue, forKey: Self.unitKey) }
    }

    var sex: Sex {
        didSet { defaults.set(sex.rawValue, forKey: Self.sexKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` distinguishes "never set" (nil) from a stored 0.
        bodyWeight = (defaults.object(forKey: Self.weightKey) as? Double)
        unit = defaults.string(forKey: Self.unitKey).flatMap(Units.init(rawValue:)) ?? .kg
        sex = defaults.string(forKey: Self.sexKey).flatMap(Sex.init(rawValue:)) ?? .male
    }

    /// Body weight normalised to kilograms for the strength math, or `nil` when
    /// unset / non-positive.
    var bodyWeightKg: Double? {
        guard let bodyWeight, bodyWeight > 0 else { return nil }
        switch unit {
        case .kg: return bodyWeight
        case .lb: return bodyWeight * 0.45359237
        }
    }
}

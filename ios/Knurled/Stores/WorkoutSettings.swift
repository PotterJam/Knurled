import Foundation
import Observation

/// Persists app-only workout presentation preferences. Engine-prescribed rest remains part of
/// the rendered session; this controls whether the iOS cockpit starts countdowns from it.
@MainActor
@Observable
final class WorkoutSettings {
    private static let restTimersKey = "knurled.restTimersEnabled"
    private let defaults: UserDefaults

    var restTimersEnabled: Bool {
        didSet { defaults.set(restTimersEnabled, forKey: Self.restTimersKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restTimersEnabled = defaults.object(forKey: Self.restTimersKey) as? Bool ?? true
    }
}

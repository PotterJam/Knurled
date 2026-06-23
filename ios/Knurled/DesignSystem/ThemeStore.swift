import Foundation
import Observation

/// Holds the user's selected colour scheme and persists it across launches.
/// Defaults to ``KnurledColorScheme/sage``.
@MainActor
@Observable
final class ThemeStore {
    private static let storageKey = "knurled.colorScheme"

    var scheme: KnurledColorScheme {
        didSet { UserDefaults.standard.set(scheme.rawValue, forKey: Self.storageKey) }
    }

    var palette: KnurledPalette { scheme.palette }

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Self.storageKey)
        scheme = stored.flatMap(KnurledColorScheme.init(rawValue:)) ?? .sage
    }
}

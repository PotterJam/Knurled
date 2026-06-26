import SwiftUI

/// A selectable colour scheme. Each scheme pairs an `accent` (the primary
/// tint used for prominent controls and the active row) with a `danger`
/// colour used for "missed"/invalid states.
struct KnurledPalette: Equatable {
    let accent: Color
    let danger: Color
}

enum KnurledColorScheme: String, CaseIterable, Identifiable {
    case brass
    case steel
    case sage
    case violet

    var id: String { rawValue }

    /// The name shown in the picker, e.g. "Brass".
    var title: String {
        switch self {
        case .brass: return "Brass"
        case .steel: return "Steel"
        case .sage: return "Sage"
        case .violet: return "Violet"
        }
    }

    /// A short description of the scheme's accent, e.g. "warm gold".
    var subtitle: String {
        switch self {
        case .brass: return "warm gold"
        case .steel: return "cool blue"
        case .sage: return "muted green"
        case .violet: return "soft violet"
        }
    }

    var palette: KnurledPalette {
        switch self {
        case .brass:
            return KnurledPalette(
                accent: Color(red: 0.83, green: 0.64, blue: 0.31),
                danger: Color(red: 0.80, green: 0.22, blue: 0.27)
            )
        case .steel:
            return KnurledPalette(
                accent: Color(red: 0.38, green: 0.56, blue: 0.92),
                danger: Color(red: 0.80, green: 0.22, blue: 0.27)
            )
        case .sage:
            return KnurledPalette(
                accent: Color(red: 0.55, green: 0.71, blue: 0.53),
                // Dusty rose, deepened a touch from the mockup for more presence.
                danger: Color(red: 0.71, green: 0.38, blue: 0.44)
            )
        case .violet:
            return KnurledPalette(
                accent: Color(red: 0.64, green: 0.47, blue: 0.92),
                danger: Color(red: 0.85, green: 0.28, blue: 0.42)
            )
        }
    }
}

enum KnurledTheme {
    static let accent = Color("AccentColor")

    static let steel = Color(red: 0.38, green: 0.42, blue: 0.47)
    static let steelDark = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let steelLight = Color(red: 0.80, green: 0.82, blue: 0.85)

    static let metal = LinearGradient(
        colors: [Color(white: 0.86), Color(white: 0.56), Color(white: 0.80)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 10
    }
}

extension Font {
    static let knurledMono = Font.system(.title3, design: .monospaced).weight(.semibold)
}

private struct KnurledPaletteKey: EnvironmentKey {
    static let defaultValue = KnurledColorScheme.sage.palette
}

extension EnvironmentValues {
    /// The active scheme's palette. Deep views (status chips, set rows) read
    /// this for the `danger` colour; `accent` flows through the standard tint.
    var knurledPalette: KnurledPalette {
        get { self[KnurledPaletteKey.self] }
        set { self[KnurledPaletteKey.self] = newValue }
    }
}

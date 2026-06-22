import SwiftUI

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

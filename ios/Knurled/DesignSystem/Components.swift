import SwiftUI

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(KnurledTheme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
            )
    }
}

extension View {
    func knurledCard() -> some View { modifier(CardModifier()) }
}

struct StatusChip: View {
    enum Style { case ok, warn, bad, neutral }
    let text: String
    var style: Style = .neutral

    private var color: Color {
        switch style {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return KnurledTheme.steel
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

struct TierBadge: View {
    let tier: String

    var body: some View {
        Text(tier.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(KnurledTheme.steel.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(KnurledTheme.steel)
    }
}

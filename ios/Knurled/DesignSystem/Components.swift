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

    @Environment(\.knurledPalette) private var palette

    private var color: Color {
        switch style {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return palette.danger
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

/// A compact horizontal "scrolly" number selector: numbers slide past a fixed
/// centre frame, and whichever lands in the middle becomes the selection. Used
/// for sets / reps instead of bulky +/- steppers.
struct HorizontalNumberPicker: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    @Environment(\.knurledPalette) private var palette
    @State private var position: Int?

    private let itemWidth: CGFloat = 46
    private let height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let sidePad = max(0, (geo.size.width - itemWidth) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(range), id: \.self) { n in
                        Text("\(n)")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(n == value ? palette.accent : .secondary)
                            .opacity(n == value ? 1 : 0.4)
                            .frame(width: itemWidth, height: height)
                            .id(n)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .contentMargins(.horizontal, sidePad, for: .scrollContent)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: itemWidth + 6, height: height - 4)
                    .allowsHitTesting(false)
            }
            .onAppear { if position == nil { position = value } }
            .onChange(of: position) { _, new in
                if let new, new != value { value = new }
            }
            .onChange(of: value) { _, new in
                if position != new { withAnimation(.snappy) { position = new } }
            }
        }
        .frame(height: height)
    }
}

struct RotationIndicator: View {
    let rotation: [String]
    let currentSession: String

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(rotation.enumerated()), id: \.offset) { idx, session in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                    }
                    Text(session.uppercased())
                        .font(.caption.weight(session == currentSession ? .bold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            session == currentSession
                                ? palette.accent
                                : Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(session == currentSession ? .white : .secondary)
                }
            }
            .padding(.horizontal, KnurledTheme.Spacing.m)
        }
        .frame(maxWidth: .infinity)
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

import SwiftUI

struct RestTimerBar: View {
    let timer: RestTimer

    var body: some View {
        if timer.isRunning {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .foregroundStyle(KnurledTheme.accent)
                Text("Rest")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(timer.remainingText)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                Spacer()
                Button("−15") { timer.add(-15) }
                    .buttonStyle(.bordered)
                Button("+15") { timer.add(15) }
                    .buttonStyle(.bordered)
                Button("Skip") { timer.skip() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

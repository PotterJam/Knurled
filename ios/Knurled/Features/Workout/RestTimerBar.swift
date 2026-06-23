import SwiftUI

struct RestTimerBar: View {
    let controller: WorkoutLiveController

    var body: some View {
        if controller.isResting {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .foregroundStyle(.tint)
                Text("Rest")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(controller.remainingText)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
                Spacer()
                HStack(spacing: 10) {
                    Button("−15") { controller.addRest(-15) }
                        .buttonStyle(.bordered)
                    Button("+15") { controller.addRest(15) }
                        .buttonStyle(.bordered)
                    Button("Skip") { controller.skipRest() }
                        .buttonStyle(.borderedProminent)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
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

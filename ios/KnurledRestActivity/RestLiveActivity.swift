import ActivityKit
import SwiftUI
import WidgetKit

struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Rest", systemImage: "timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(context.state.exerciseTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                countdown(to: context.state.endDate)
                    .font(.system(.largeTitle, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(width: 110, alignment: .trailing)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Rest", systemImage: "timer")
                        .foregroundStyle(.cyan)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(to: context.state.endDate)
                        .font(.title3.monospacedDigit())
                        .frame(width: 64)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.exerciseTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                countdown(to: context.state.endDate)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    private func countdown(to endDate: Date) -> Text {
        Text(timerInterval: Date.now...max(Date.now.addingTimeInterval(1), endDate), countsDown: true)
    }
}

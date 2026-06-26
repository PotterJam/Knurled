import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestActivityAttributes.self) { context in
            LockScreenView(state: context.state, workoutName: context.attributes.workoutName)
                .padding()
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.exerciseTitle).font(.headline).lineLimit(1)
                        Text(state.compactSetLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .resting {
                        countdown(to: state.restEndDate)
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .frame(width: 70)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    controls(state)
                }
            } compactLeading: {
                Image(systemName: state.phase == .resting ? "timer" : "dumbbell.fill")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if state.phase == .resting {
                    countdown(to: state.restEndDate).monospacedDigit().frame(width: 44)
                } else if state.phase == .ready {
                    Text(state.isWarmup ? "W\(state.setNumber)" : "S\(state.setNumber)").monospacedDigit()
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            } minimal: {
                Image(systemName: state.phase == .resting ? "timer" : "dumbbell.fill")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    @ViewBuilder private func controls(_ state: RestActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .ready:
            if state.isAmrap {
                AmrapControls(reps: state.amrapReps)
            } else {
                Button(intent: LogSetIntent()) {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .tint(.cyan)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .resting:
            HStack(spacing: 10) {
                Button(intent: AddRestIntent()) {
                    Label("30s", systemImage: "plus")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .tint(.secondary)
                Button(intent: SkipRestIntent()) {
                    Label("Skip", systemImage: "forward.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .tint(.cyan)
            }
        case .finished:
            Text("Open Knurled to finish").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func countdown(to endDate: Date) -> Text {
        Text(timerInterval: Date.now...max(Date.now.addingTimeInterval(1), endDate), countsDown: true)
    }
}

private struct LockScreenView: View {
    let state: RestActivityAttributes.ContentState
    let workoutName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(workoutName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(state.exerciseProgress).font(.caption2).foregroundStyle(.secondary)
            }

            switch state.phase {
            case .ready:
                readyBody
            case .resting:
                restingBody
            case .finished:
                Label("Workout complete", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
    }

    private var readyBody: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.exerciseTitle).font(.headline).lineLimit(1)
                Text(state.compactSetLine)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if state.isAmrap {
                AmrapControls(reps: state.amrapReps)
                    .frame(maxWidth: 176)
            } else {
                Button(intent: LogSetIntent()) {
                    Image(systemName: "checkmark.circle")
                        .font(.title3)
                        .frame(width: 40, height: 30)
                }
                .tint(.cyan)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var restingBody: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Rest", systemImage: "timer")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Next: \(state.exerciseTitle)").font(.subheadline).lineLimit(1)
                Text(state.compactSetLine)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                Text(timerInterval: Date.now...max(Date.now.addingTimeInterval(1), state.restEndDate), countsDown: true)
                    .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(width: 96, alignment: .trailing)
                HStack(spacing: 8) {
                    Button(intent: AddRestIntent()) {
                        Image(systemName: "plus")
                    }
                    .tint(.secondary)
                    Button(intent: SkipRestIntent()) {
                        Image(systemName: "forward.fill")
                    }
                    .tint(.cyan)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

/// −/+ stepper plus a tick button for an AMRAP final set, all driven by App Intents so it
/// works directly on the lock screen.
private struct AmrapControls: View {
    let reps: Int

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: AmrapStepIntent(delta: -1)) {
                Image(systemName: "minus")
            }
            .tint(.secondary)
            Text("\(reps)")
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(minWidth: 34)
            Button(intent: AmrapStepIntent(delta: 1)) {
                Image(systemName: "plus")
            }
            .tint(.secondary)
            Button(intent: LogSetIntent()) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .tint(.cyan)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

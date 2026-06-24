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
                        Text(state.setProgress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .resting {
                        countdown(to: state.restEndDate)
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .frame(width: 70)
                    } else if state.phase == .ready {
                        Text(state.loadReps).font(.caption).foregroundStyle(.secondary)
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
                    Text("S\(state.setNumber)").monospacedDigit()
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
            if state.isWarmup {
                WarmupControls(advanceTitle: state.warmupAdvanceTitle)
            } else if state.isAmrap {
                AmrapControls(reps: state.amrapReps)
            } else {
                Button(intent: LogSetIntent()) {
                    Label("Log set", systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .tint(.cyan)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.exerciseTitle).font(.headline).lineLimit(1)
                    Text("\(state.setProgress) · \(state.loadReps)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if state.isWarmup {
                WarmupControls(advanceTitle: state.warmupAdvanceTitle)
            } else if state.isAmrap {
                AmrapControls(reps: state.amrapReps)
            } else {
                Button(intent: LogSetIntent()) {
                    Label("Log set", systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .tint(.cyan)
            }
        }
    }

    private var restingBody: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Rest", systemImage: "timer")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Next: \(state.exerciseTitle)").font(.subheadline).lineLimit(1)
                Text("\(state.setProgress) · \(state.loadReps)")
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

/// A warmup ramp set: log it, or move past this guidance-only set. Warmups never start
/// a rest countdown.
private struct WarmupControls: View {
    let advanceTitle: String

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: SkipWarmupIntent()) {
                Label(advanceTitle, systemImage: "forward.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .tint(.secondary)
            Button(intent: LogSetIntent()) {
                Label("Log warmup", systemImage: "checkmark.circle.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .tint(.orange)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// −/+ stepper plus a Log button for an AMRAP final set, all driven by App Intents so it
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
                Label("Log \(reps)", systemImage: "checkmark.circle.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .tint(.cyan)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

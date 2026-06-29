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
                    } else if state.phase == .ready {
                        SetProgressDots(total: state.totalSets, current: state.setNumber)
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
            if state.isWarmup {
                HStack(spacing: 10) {
                    Button(intent: LogSetIntent()) {
                        Label("Log", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .tint(.cyan)
                    Button(intent: SkipWarmupIntent()) {
                        Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                LogInAppButton()
            }
        case .resting:
            HStack(spacing: 10) {
                Button(intent: AddRestIntent()) {
                    Label("30s", systemImage: "plus").lineLimit(1).frame(maxWidth: .infinity)
                }
                .tint(.secondary)
                Button(intent: SkipRestIntent()) {
                    Label("Skip", systemImage: "forward.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
                .tint(.cyan)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        VStack(alignment: .leading, spacing: 12) {
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

    // MARK: Ready (a set is staged)

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.exerciseTitle).font(.title3.weight(.semibold)).lineLimit(1)
                if state.isWarmup {
                    Text("WARM-UP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                SetProgressDots(total: state.totalSets, current: state.setNumber)
            }

            Text(state.loadReps)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(state.needsLoad ? .orange : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Snap to the new value on a stepper tap instead of the default slow cross-fade.
                .contentTransition(.identity)

            readyControls
        }
    }

    @ViewBuilder private var readyControls: some View {
        if state.isWarmup {
            HStack(spacing: 10) {
                Button(intent: LogSetIntent()) {
                    Label("Log", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                }
                .tint(.cyan)
                Button(intent: SkipWarmupIntent()) {
                    Label("Skip warm-up", systemImage: "forward.fill").frame(maxWidth: .infinity)
                }
                .tint(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            LogInAppButton(controlSize: .large)
        }
    }

    // MARK: Resting

    private var restingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mirror the ready/log layout — same exercise, set dots and load×reps — so resting
            // shows what's coming up next rather than a different-looking panel.
            HStack(alignment: .firstTextBaseline) {
                Text(state.exerciseTitle).font(.title3.weight(.semibold)).lineLimit(1)
                if state.isWarmup {
                    Text("WARM-UP")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                SetProgressDots(total: state.totalSets, current: state.setNumber)
            }

            HStack(alignment: .center) {
                Text(state.loadReps)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(state.needsLoad ? .orange : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("REST").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(timerInterval: Date.now...max(Date.now.addingTimeInterval(1), state.restEndDate), countsDown: true)
                        .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                        .frame(width: 96, alignment: .trailing)
                }
            }

            HStack(spacing: 10) {
                Button(intent: AddRestIntent()) {
                    Label("30s", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .tint(.secondary)
                Button(intent: SkipRestIntent()) {
                    Label("Skip", systemImage: "forward.fill").frame(maxWidth: .infinity)
                }
                .tint(.cyan)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// A row of dots showing position within the exercise — filled for done sets, ringed for current.
private struct SetProgressDots: View {
    let total: Int
    let current: Int

    var body: some View {
        if total > 0 {
            HStack(spacing: 4) {
                ForEach(1...max(total, 1), id: \.self) { index in
                    Circle()
                        .strokeBorder(.cyan, lineWidth: 1.5)
                        .background(Circle().fill(index < current ? Color.cyan : .clear))
                        .frame(width: 7, height: 7)
                        .opacity(index <= current ? 1 : 0.4)
                }
            }
        }
    }
}

/// A single button that opens the app on the current set with the reps editor ready to type,
/// rather than logging from the lock screen. Replaces the old on-activity weight/AMRAP steppers.
private struct LogInAppButton: View {
    var controlSize: ControlSize = .small

    var body: some View {
        Button(intent: EditRepsIntent()) {
            Label("Log set", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .tint(.cyan)
        .buttonStyle(.bordered)
        .controlSize(controlSize)
    }
}

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
            if state.isAmrap {
                AmrapControls(reps: state.amrapReps)
            } else if state.isWarmup {
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
                WeightLogRow(needsLoad: state.needsLoad)
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
        if state.isAmrap {
            AmrapControls(reps: state.amrapReps)
        } else if state.isWarmup {
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
            WeightLogRow(needsLoad: state.needsLoad)
        }
    }

    // MARK: Resting

    private var restingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Rest", systemImage: "timer")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Next: \(state.exerciseTitle)").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(state.compactSetLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(timerInterval: Date.now...max(Date.now.addingTimeInterval(1), state.restEndDate), countsDown: true)
                    .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                    .frame(width: 96, alignment: .trailing)
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

            // Annotate the set just completed with an RPE while you rest.
            HStack(spacing: 10) {
                Text(state.rpeText ?? "RPE")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state.rpe == nil ? .secondary : .primary)
                    .contentTransition(.identity)
                Spacer()
                Button(intent: RpeStepIntent(delta: -0.5)) {
                    Image(systemName: "minus")
                }
                .tint(.secondary)
                Button(intent: RpeStepIntent(delta: 0.5)) {
                    Image(systemName: "plus")
                }
                .tint(.secondary)
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

/// −/＋ weight steppers flanking a log button, so the load can be set or corrected on the lock
/// screen. When a weight is still required the log is replaced by a clear prompt.
private struct WeightLogRow: View {
    let needsLoad: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: LoadStepIntent(steps: -1)) {
                Image(systemName: "minus")
            }
            .tint(.secondary)

            if needsLoad {
                Text("Set a weight")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
            } else {
                Button(intent: LogSetIntent()) {
                    Label("Log set", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.cyan)
            }

            Button(intent: LoadStepIntent(steps: 1)) {
                Image(systemName: "plus")
            }
            .tint(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
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
                .contentTransition(.identity)
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

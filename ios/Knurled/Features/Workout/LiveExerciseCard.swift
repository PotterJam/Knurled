import SwiftUI

struct LiveExerciseCard: View {
    let live: LiveItem
    let controller: WorkoutLiveController
    @State private var showAdjust = false
    @State private var showSwap = false
    @State private var editingSet: LiveSet?

    @Environment(\.knurledPalette) private var palette

    private var isCurrentExercise: Bool { controller.isCurrentExercise(live) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(live.item.display.title).font(.headline)
                Spacer()
                if let tier = WorkoutFormat.tier(fromLane: live.item.progressionLane) {
                    TierBadge(tier: tier)
                }
            }

            loadLine

            if live.isSwapped {
                Label(
                    "Performing \(live.performedExerciseName) · \(swapPolicyText)",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if live.skipped {
                skippedBody
            } else {
                if live.hasWarmups { warmupSection }

                VStack(spacing: 6) {
                    ForEach(live.sets) { set in
                        SetRowView(
                            set: set,
                            isAmrap: live.isAmrap,
                            isLastSet: set.id == live.sets.last?.id,
                            isCurrent: controller.isCurrent(set),
                            onEdit: { editingSet = set },
                            onLogged: { controller.didLogSetInApp(item: live) },
                            onChanged: { controller.modelChanged() }
                        )
                        if set.id != live.sets.last?.id { Divider() }
                    }
                }

                footer
            }
        }
        .knurledCard()
        .opacity(live.skipped ? 0.55 : (isCurrentExercise ? 1 : 0.7))
        .overlay {
            if isCurrentExercise {
                RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 2)
            }
        }
        .sheet(isPresented: $showAdjust) { AdjustTodaySheet(live: live) }
        .sheet(isPresented: $showSwap) { SwapExerciseSheet(live: live) }
        .sheet(item: $editingSet) { set in SetDetailSheet(set: set) }
    }

    @ViewBuilder private var warmupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Warm-up", systemImage: "flame")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
            }

            ForEach(live.warmups) { set in
                SetRowView(
                    set: set,
                    isAmrap: false,
                    isLastSet: set.id == live.warmups.last?.id,
                    isCurrent: controller.isCurrent(set),
                    isWarmup: true,
                    canStartHere: canStartWarmup(at: set),
                    onEdit: { editingSet = set },
                    onLogged: { controller.didLogSetInApp(item: live, wasWarmup: true) },
                    onChanged: { controller.modelChanged() },
                    onAdvanceWarmup: { controller.advanceCurrentWarmup() },
                    onStartHere: { controller.startWarmups(at: set, in: live) }
                )
                if set.id != live.warmups.last?.id { Divider() }
            }

            Divider().padding(.vertical, 2)
        }
    }

    private func canStartWarmup(at set: LiveSet) -> Bool {
        isCurrentExercise && set.isWarmup && !set.logged && !controller.isCurrent(set)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 16) {
            Button { showAdjust = true } label: {
                Label("Adjust today", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            if live.canSwap {
                Button { showSwap = true } label: {
                    Label("Swap", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            if live.isComplete {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Button(role: .destructive) {
                    controller.setSkipped(live, true)
                } label: {
                    Label("Skip", systemImage: "forward.end")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.footnote)
    }

    private var skippedBody: some View {
        HStack(spacing: 12) {
            Label("Skipped", systemImage: "forward.end.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                controller.setSkipped(live, false)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
        }
    }

    private var swapPolicyText: String {
        live.swapPolicy == .progressionEquivalent ? "counts toward progression" : "tracking only"
    }

    @ViewBuilder private var loadLine: some View {
        if live.isAdjusted, let today = live.todayLoad {
            HStack(spacing: 12) {
                Text("Prescribed: \(live.prescribedLoad ?? "bodyweight")")
                    .foregroundStyle(.secondary)
                Text("Today: \(today)")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
        } else {
            Text(live.item.display.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct SetRowView: View {
    let set: LiveSet
    let isAmrap: Bool
    let isLastSet: Bool
    /// The single active set across the whole workout. Only this row shows the Done/Missed
    /// (or AMRAP) controls; logged rows show their result and upcoming rows are dimmed, so it
    /// is always obvious which set is current.
    let isCurrent: Bool
    var isWarmup: Bool = false
    var canStartHere: Bool = false
    var onEdit: () -> Void
    var onLogged: () -> Void
    var onChanged: () -> Void
    var onAdvanceWarmup: (() -> Void)?
    var onStartHere: (() -> Void)?

    @Environment(\.knurledPalette) private var palette
    @State private var entering = false

    private var isAmrapFinal: Bool { isAmrap && isLastSet }
    private var isEntering: Bool { isCurrent && (isAmrapFinal || entering) }

    private var setTitle: String {
        if isAmrapFinal {
            return "Set \(set.id)+ · min \(set.prescribed.targetReps) reps"
        }
        let label = isWarmup ? "Warm-up" : "Set"
        return "\(label) \(set.id) · \(set.prescribed.targetReps) reps"
    }

    var body: some View {
        @Bindable var set = set
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setTitle)
                        .font(.subheadline)
                        .fontWeight(isCurrent && !set.logged ? .semibold : .regular)
                    if let load = set.load {
                        Text(load + (set.isAdjusted ? " · today" : ""))
                            .font(.caption)
                            .foregroundStyle(set.isAdjusted ? .orange : .secondary)
                    }
                }
                Spacer()
                if set.bypassed {
                    if canStartHere {
                        Button {
                            onStartHere?()
                        } label: {
                            Label("Start here", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Label("Passed", systemImage: "arrow.forward.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else if set.logged {
                    HStack(spacing: 10) {
                        Button(action: onEdit) {
                            Text("\(set.reps)").font(.body.monospaced().weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        Button {
                            set.logged = false
                            onChanged()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo set")
                    }
                } else if isWarmup && isCurrent {
                    HStack(spacing: 8) {
                        Button(isLastSet ? "Start sets" : "Next") {
                            onAdvanceWarmup?()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Done") {
                            set.reps = set.prescribed.targetReps
                            set.logged = true
                            onLogged()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                } else if isWarmup && canStartHere {
                    Button {
                        onStartHere?()
                    } label: {
                        Label("Start here", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if isCurrent && !isEntering {
                    HStack(spacing: 8) {
                        Button("Missed") {
                            set.reps = set.prescribed.targetReps
                            entering = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.danger)
                        .controlSize(.small)
                        Button("Done") {
                            set.reps = set.prescribed.targetReps
                            set.logged = true
                            if isLastSet { onChanged() } else { onLogged() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if isEntering && !set.logged {
                HStack(spacing: 12) {
                    RepsWheel(reps: $set.reps)
                    Text("reps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        set.logged = true
                        entering = false
                        if isLastSet { onChanged() } else { onLogged() }
                    } label: {
                        Text("Save")
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(rowOpacity)
    }

    /// Logged and current rows are full strength; sets still ahead are dimmed.
    private var rowOpacity: Double {
        if set.bypassed { return 0.35 }
        if set.logged || isCurrent { return 1 }
        return 0.45
    }
}

struct RepsWheel: View {
    @Binding var reps: Int

    var body: some View {
        Picker("Reps", selection: $reps) {
            ForEach(0...99, id: \.self) { value in
                Text("\(value)")
                    .font(.title3.monospacedDigit())
                    .tag(value)
            }
        }
        .labelsHidden()
        .pickerStyle(.wheel)
        .frame(width: 76, height: 104)
        .clipped()
    }
}

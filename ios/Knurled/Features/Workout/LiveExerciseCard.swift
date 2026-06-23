import SwiftUI

struct LiveExerciseCard: View {
    let live: LiveItem
    let restTimer: RestTimer
    @State private var showAdjust = false
    @State private var showSwap = false
    @State private var editingSet: LiveSet?

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

            VStack(spacing: 6) {
                ForEach(live.sets) { set in
                    SetRowView(
                        set: set,
                        isAmrap: live.isAmrap,
                        isLastSet: set.id == live.sets.last?.id,
                        onEdit: { editingSet = set },
                        onLogged: {
                            restTimer.start(
                                seconds: live.item.rest.seconds,
                                exercise: live.item.display.title
                            )
                        }
                    )
                    if set.id != live.sets.last?.id { Divider() }
                }
            }

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
                }
            }
            .font(.footnote)
        }
        .knurledCard()
        .sheet(isPresented: $showAdjust) { AdjustTodaySheet(live: live) }
        .sheet(isPresented: $showSwap) { SwapExerciseSheet(live: live) }
        .sheet(item: $editingSet) { set in SetDetailSheet(set: set) }
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
    var onEdit: () -> Void
    var onLogged: () -> Void

    @Environment(\.knurledPalette) private var palette
    @State private var entering = false

    private var isAmrapFinal: Bool { isAmrap && isLastSet }
    private var isEntering: Bool { isAmrapFinal || entering }

    private var setTitle: String {
        if isAmrapFinal {
            return "Set \(set.id)+ · min \(set.prescribed.targetReps) reps"
        }
        return "Set \(set.id) · \(set.prescribed.targetReps) reps"
    }

    var body: some View {
        @Bindable var set = set
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setTitle).font(.subheadline)
                    if let load = set.load {
                        Text(load + (set.isAdjusted ? " · today" : ""))
                            .font(.caption)
                            .foregroundStyle(set.isAdjusted ? .orange : .secondary)
                    }
                }
                Spacer()
                if set.logged {
                    HStack(spacing: 10) {
                        Button(action: onEdit) {
                            Text("\(set.reps)").font(.body.monospaced().weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        Button {
                            set.logged = false
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Undo set")
                    }
                } else if !isEntering {
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
                            if !isLastSet { onLogged() }
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
                        if !isLastSet { onLogged() }
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

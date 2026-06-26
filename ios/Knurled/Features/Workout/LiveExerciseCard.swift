import SwiftUI

struct LiveExerciseCard: View {
    let live: LiveItem
    let controller: WorkoutLiveController
    var isCollapsedForDrag = false
    @State private var showChange = false
    @State private var editingSet: LiveSet?
    @State private var editingValue: SetValueEdit?

    @Environment(\.knurledPalette) private var palette

    private var isCurrentExercise: Bool { controller.isCurrentExercise(live) }

    var body: some View {
        if isCollapsedForDrag {
            collapsedBody
        } else {
            fullBody
        }
    }

    private var collapsedBody: some View {
        HStack(spacing: 10) {
            Text(live.item.display.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let tier = WorkoutFormat.tier(fromLane: live.item.progressionLane) {
                TierBadge(tier: tier)
            }
            if let phaseText {
                StatusChip(text: phaseText, style: .neutral)
            }
            if live.isTrackingOnlyExtra {
                StatusChip(text: "Extra", style: .neutral)
            }
            Spacer()
            Image(systemName: live.isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(live.isComplete ? palette.accent : .secondary)
        }
        .padding(.horizontal, KnurledTheme.Spacing.m)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
        )
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(live.item.display.title).font(.headline)
                Spacer()
                if live.isTrackingOnlyExtra {
                    StatusChip(text: "Extra", style: .neutral)
                }
                if let phaseText {
                    StatusChip(text: phaseText, style: .neutral)
                }
                if let tier = WorkoutFormat.tier(fromLane: live.item.progressionLane) {
                    TierBadge(tier: tier)
                }
                if live.phase == .main {
                    Button { showChange = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Exercise options")
                }
            }

            if live.isSwapped {
                Label(
                    "Performing \(live.performedExerciseName) · \(swapPolicyText)",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if live.hasWarmups { warmupSection }

            VStack(spacing: 6) {
                ForEach(live.sets) { set in
                    SetRowView(
                        set: set,
                        isAmrap: live.isAmrap,
                        isLastSet: set.id == live.lastRequiredSetID,
                        isCurrent: controller.isCurrent(set),
                        onEditLoad: { editingValue = .load(set) },
                        onEditReps: { editingValue = .reps(set) },
                        onEditDetails: { editingSet = set },
                        onToggled: { controller.toggle(set: set, in: live) },
                        onChanged: { controller.modelChanged() }
                    )
                    if set.id != live.sets.last?.id { Divider() }
                }
            }

            addSetRow
            footer
        }
        .knurledCard()
        .opacity(isCurrentExercise ? 1 : 0.7)
        .overlay {
            if isCurrentExercise {
                RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                    .strokeBorder(palette.accent, lineWidth: 2)
            }
        }
        // Tapping an unfocused, unfinished card jumps the cursor onto it — the way to do exercises
        // out of order (e.g. when the equipment you wanted is busy) now that there's no skip.
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCurrentExercise && !live.isComplete { controller.focus(live) }
        }
        .accessibilityHint(isCurrentExercise || live.isComplete ? "" : "Double tap to work on this exercise next")
        .sheet(isPresented: $showChange) {
            ChangeExerciseSheet(live: live) {
                controller.modelChanged()
            }
        }
        .sheet(item: $editingSet) { set in SetDetailSheet(set: set) }
        .sheet(item: $editingValue) { edit in
            switch edit {
            case .load(let set):
                LoadValueEditor(set: set, units: live.units) {
                    controller.modelChanged()
                }
                .presentationDetents([.height(250)])
            case .reps(let set):
                RepsValueEditor(set: set) {
                    controller.modelChanged()
                }
                .presentationDetents([.height(300)])
            }
        }
    }

    @ViewBuilder private var warmupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let visibleWarmups = live.visibleWarmups
            ForEach(visibleWarmups) { set in
                SetRowView(
                    set: set,
                    isAmrap: false,
                    isLastSet: set.id == live.warmups.last?.id,
                    isCurrent: controller.isCurrent(set),
                    isWarmup: true,
                    onEditLoad: { editingValue = .load(set) },
                    onEditReps: { editingValue = .reps(set) },
                    onEditDetails: { editingSet = set },
                    onToggled: { controller.toggle(set: set, in: live) },
                    onChanged: { controller.modelChanged() }
                )
                if set.id != visibleWarmups.last?.id { Divider() }
            }

            Divider().padding(.vertical, 2)
        }
    }

    private var addSetRow: some View {
        Button {
            live.addSet()
            controller.modelChanged()
        } label: {
            Label("Add set", systemImage: "plus.circle")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.accent)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 16) {
            Spacer()
            if live.isComplete {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if !isCurrentExercise {
                Label("Tap to do next", systemImage: "hand.tap")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    private var swapPolicyText: String {
        live.swapPolicy == .progressionEquivalent ? "counts toward progression" : "tracking only"
    }

    private var phaseText: String? {
        switch live.phase {
        case .main: return nil
        case .warmup: return "Warmup"
        case .warmdown: return "Warmdown"
        }
    }

}

private enum SetValueEdit: Identifiable {
    case load(LiveSet)
    case reps(LiveSet)

    var id: String {
        switch self {
        case .load(let set): "load-\(ObjectIdentifier(set).hashValue)"
        case .reps(let set): "reps-\(ObjectIdentifier(set).hashValue)"
        }
    }
}

struct SetRowView: View {
    let set: LiveSet
    let isAmrap: Bool
    let isLastSet: Bool
    /// The single active set across the whole workout. Rows stay directly actionable even when
    /// they are not current, but the active one gets a little extra emphasis.
    let isCurrent: Bool
    var isWarmup: Bool = false
    var onEditLoad: () -> Void
    var onEditReps: () -> Void
    var onEditDetails: () -> Void
    var onToggled: () -> Void
    var onChanged: () -> Void

    @Environment(\.knurledPalette) private var palette

    private var isAmrapFinal: Bool { isAmrap && isLastSet }

    var body: some View {
        @Bindable var set = set
        HStack(spacing: 12) {
            Button(action: onToggled) {
                Image(systemName: set.logged ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(set.logged ? palette.accent : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.logged ? "Undo set" : "Mark set done")

            editablePrescription
                .font(.subheadline.weight(isCurrent && !set.logged ? .semibold : .regular))

            Spacer(minLength: 8)

            if set.logged {
                Button(action: onEditDetails) {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Set details")
            }
        }
        .frame(minHeight: 34)
        .padding(.vertical, 1)
        .opacity(rowOpacity)
    }

    private var editablePrescription: some View {
        HStack(spacing: 5) {
            if isWarmup {
                Text("W")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            ValueChip(text: loadText, isChanged: set.load != set.prescribed.load, action: onEditLoad)
            Text("×")
                .foregroundStyle(.secondary)
            ValueChip(text: "\(displayReps)\(amrapMarker)\(rpeSuffix)", isChanged: repsChanged, action: onEditReps)
        }
    }

    private var prefix: String {
        return isWarmup ? "W " : ""
    }

    private var loadText: String {
        return set.load ?? "bodyweight"
    }

    private var displayReps: Int {
        return isAmrapFinal && !set.logged && !repsChanged ? set.prescribed.targetReps : set.reps
    }

    private var amrapMarker: String {
        return isAmrapFinal ? "+" : ""
    }

    private var rpeSuffix: String {
        guard let rpe = set.rpeText else { return "" }
        return " @\(rpe)"
    }

    private var repsChanged: Bool {
        return set.reps != set.prescribed.targetReps
    }

    private var rowOpacity: Double {
        if set.bypassed { return 0.35 }
        return 1
    }
}

private struct ValueChip: View {
    let text: String
    let isChanged: Bool
    var action: () -> Void

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.monospacedDigit().weight(isChanged ? .semibold : .medium))
                .foregroundStyle(isChanged ? .orange : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (isChanged ? Color.orange.opacity(0.14) : Color(uiColor: .tertiarySystemFill)),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct LoadValueEditor: View {
    let set: LiveSet
    let units: Units
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(set: LiveSet, units: Units, onChanged: @escaping () -> Void) {
        self.set = set
        self.units = units
        self.onChanged = onChanged
        let parsed = LoadControl.parse(set.load, defaultUnit: units)
        _text = State(initialValue: parsed.map { Self.numberText($0.value) } ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    ForEach(decrements, id: \.self) { amount in
                        Button(formatDelta(-amount)) { adjust(by: -amount) }
                            .buttonStyle(.bordered)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                        .frame(width: 130)
                        .onChange(of: text) { _, _ in applyText() }
                    Text(units.rawValue)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ForEach(increments, id: \.self) { amount in
                        Button(formatDelta(amount)) { adjust(by: amount) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .navigationTitle("Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { reset() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var decrements: [Double] {
        switch units {
        case .kg: [10, 5, 2.5]
        case .lb: [20, 10, 5]
        }
    }

    private var increments: [Double] {
        switch units {
        case .kg: [2.5, 5, 10]
        case .lb: [5, 10, 20]
        }
    }

    private func adjust(by delta: Double) {
        let value = max(0, currentValue + delta)
        text = Self.numberText(value)
        apply(value)
    }

    private func reset() {
        set.load = set.prescribed.load
        text = LoadControl.parse(set.load, defaultUnit: units).map { Self.numberText($0.value) } ?? ""
        onChanged()
    }

    private func applyText() {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
        apply(max(0, value))
    }

    private func apply(_ value: Double) {
        set.load = LoadControl.format(value, unit: units)
        onChanged()
    }

    private var currentValue: Double {
        Double(text.trimmingCharacters(in: .whitespaces))
            ?? LoadControl.parse(set.load, defaultUnit: units)?.value
            ?? 0
    }

    private func formatDelta(_ value: Double) -> String {
        let number = Self.numberText(value)
        return value > 0 ? "+\(number)" : number
    }

    private static func numberText(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}

private struct RepsValueEditor: View {
    let set: LiveSet
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var set = set
        NavigationStack {
            Picker("Reps", selection: Binding(
                get: { set.reps },
                set: {
                    set.reps = $0
                    onChanged()
                }
            )) {
                ForEach(0...99, id: \.self) { reps in
                    Text("\(reps)").tag(reps)
                }
            }
            .pickerStyle(.wheel)
            .navigationTitle("Reps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        set.reps = set.prescribed.targetReps
                        onChanged()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

import SwiftUI

struct LiveExerciseCard: View {
    let live: LiveItem
    let controller: WorkoutLiveController
    /// Non-nil only for exercises the user added this session, which can be removed.
    var onDelete: (() -> Void)? = nil
    @State private var showChange = false
    @State private var confirmDelete = false
    @State private var editingValue: SetValueEdit?

    @Environment(\.knurledPalette) private var palette

    private var isCurrentExercise: Bool { controller.isCurrentExercise(live) }

    var body: some View {
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
                if onDelete != nil {
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.danger)
                    .accessibilityLabel("Remove exercise")
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

            VStack(spacing: 3) {
                ForEach(Array(live.sets.enumerated()), id: \.element.id) { index, set in
                    SetRowView(
                        set: set,
                        indexLabel: "\(index + 1)",
                        isAmrap: live.isAmrap,
                        isLastSet: set.id == live.lastRequiredSetID,
                        isCurrent: controller.isCurrent(set),
                        onEditLoad: { editingValue = .load(set) },
                        onEditReps: { editingValue = .reps(set) },
                        onEditRPE: { editingValue = .rpe(set) },
                        onToggled: { controller.toggle(set: set, in: live) },
                        onChanged: { controller.modelChanged() },
                        onDelete: set.isExtra ? {
                            withAnimation(.snappy) {
                                live.removeSet(set)
                                controller.modelChanged()
                            }
                        } : nil
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
        .sheet(isPresented: $showChange) {
            ChangeExerciseSheet(live: live) {
                controller.modelChanged()
            }
        }
        .setEditingSheets(editingValue: $editingValue, units: live.units) {
            controller.modelChanged()
        }
        .confirmationDialog(
            "Remove \(live.item.display.title)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove Exercise", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var warmupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let visibleWarmups = live.visibleWarmups
            ForEach(Array(visibleWarmups.enumerated()), id: \.element.id) { _, set in
                SetRowView(
                    set: set,
                    indexLabel: "W",
                    isAmrap: false,
                    isLastSet: set.id == live.warmups.last?.id,
                    isCurrent: controller.isCurrent(set),
                    onEditLoad: { editingValue = .load(set) },
                    onEditReps: { editingValue = .reps(set) },
                    onEditRPE: { editingValue = .rpe(set) },
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
        if live.isComplete {
            HStack {
                Spacer()
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
            .font(.footnote)
        }
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

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 40
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum SetValueEdit: Identifiable {
    case load(LiveSet)
    case reps(LiveSet)
    case rpe(LiveSet)

    var id: String {
        switch self {
        case .load(let set): "load-\(ObjectIdentifier(set).hashValue)"
        case .reps(let set): "reps-\(ObjectIdentifier(set).hashValue)"
        case .rpe(let set): "rpe-\(ObjectIdentifier(set).hashValue)"
        }
    }
}

/// Hosts the load / reps / RPE editing sheets shared by the working-set card and the combined
/// warm-up block so both edit a set the same way.
private struct SetEditingSheets: ViewModifier {
    @Binding var editingValue: SetValueEdit?
    let units: Units
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $editingValue) { edit in
                switch edit {
                case .load(let set):
                    LoadValueEditor(set: set, units: units, onChanged: onChanged)
                        .presentationDetents([.height(250)])
                case .reps(let set):
                    RepsValueEditor(set: set, onChanged: onChanged)
                        .presentationDetents([.height(300)])
                case .rpe(let set):
                    RPEValueEditor(set: set, onChanged: onChanged)
                        .presentationDetents([.height(300)])
                }
            }
    }
}

extension View {
    func setEditingSheets(
        editingValue: Binding<SetValueEdit?>,
        units: Units,
        onChanged: @escaping () -> Void
    ) -> some View {
        modifier(SetEditingSheets(
            editingValue: editingValue,
            units: units,
            onChanged: onChanged
        ))
    }
}

/// The small leading chip showing the set number (1, 2, 3…) or "W" for a warm-up set.
private struct SetIndexBadge: View {
    let label: String
    let isCurrent: Bool

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(isCurrent ? palette.accent : .secondary)
            .frame(width: 26, height: 26)
            .background(
                Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.accent, lineWidth: 1.5)
                }
            }
    }
}

struct SetRowView: View {
    let set: LiveSet
    /// Number shown in the leading badge — the set position, or "W"/"W1"… for warm-ups.
    let indexLabel: String
    let isAmrap: Bool
    let isLastSet: Bool
    /// The single active set across the whole workout. Rows stay directly actionable even when
    /// they are not current, but the active one gets a little extra emphasis.
    let isCurrent: Bool
    var onEditLoad: () -> Void
    var onEditReps: () -> Void
    var onEditRPE: () -> Void
    var onToggled: () -> Void
    var onChanged: () -> Void
    /// Non-nil only for user-added sets, which can be swiped away.
    var onDelete: (() -> Void)? = nil

    @Environment(\.knurledPalette) private var palette
    @State private var offset: CGFloat = 0
    @State private var revealed = false
    @State private var rowHeight: CGFloat = 40

    private let revealWidth: CGFloat = 76
    private var isAmrapFinal: Bool { isAmrap && isLastSet }

    var body: some View {
        if onDelete != nil {
            swipeableRow
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        @Bindable var set = set
        return HStack(spacing: 12) {
            SetIndexBadge(label: indexLabel, isCurrent: isCurrent && !set.logged)

            prescriptionView
                .font(.subheadline.weight(isCurrent && !set.logged ? .semibold : .regular))

            Spacer(minLength: 8)

            Button(action: onToggled) {
                Image(systemName: set.logged ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(set.logged ? palette.accent : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.logged ? "Undo set" : "Mark set done")
        }
        .frame(minHeight: 34)
        .opacity(rowOpacity)
    }

    private var swipeableRow: some View {
        ZStack(alignment: .trailing) {
            Button {
                onDelete?()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: revealWidth, height: rowHeight)
                    .background(palette.danger, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete set")
            .opacity(offset < -1 ? 1 : 0)

            rowContent
                .background(
                    GeometryReader { geo in
                        Color(uiColor: .secondarySystemBackground)
                            .preference(key: RowHeightKey.self, value: geo.size.height)
                    }
                )
                .offset(x: offset)
                .gesture(swipeGesture)
        }
        .onPreferenceChange(RowHeightKey.self) { rowHeight = $0 }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base = revealed ? -revealWidth : 0
                offset = max(-revealWidth, min(0, base + value.translation.width))
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    revealed = offset < -revealWidth / 2
                    offset = revealed ? -revealWidth : 0
                }
            }
    }

    private var prescriptionView: some View {
        HStack(spacing: 5) {
            if showPrescribedReference {
                Text(prescribedText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .strikethrough()
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ValueChip(text: loadText, isChanged: loadChanged, action: onEditLoad)
            Text("×")
                .foregroundStyle(.secondary)
            ValueChip(text: "\(displayReps)\(amrapMarker)", isChanged: repsChanged, action: onEditReps)
            if showRPEChip {
                RPEChip(text: rpeText, hasValue: set.rpe != nil, action: onEditRPE)
            }
        }
    }

    private var showPrescribedReference: Bool {
        self.set.logged && (loadChanged || repsChanged)
    }

    private var prescribedText: String {
        let load = set.prescribed.load ?? "bw"
        return "\(load)×\(set.prescribed.targetReps)\(set.prescribed.amrap ? "+" : "")"
    }

    private var loadText: String {
        return set.load ?? "bodyweight"
    }

    private var loadChanged: Bool {
        return set.load != set.prescribed.load
    }

    private var displayReps: Int {
        return isAmrapFinal && !set.logged && !repsChanged ? set.prescribed.targetReps : set.reps
    }

    private var amrapMarker: String {
        return isAmrapFinal ? "+" : ""
    }

    private var showRPEChip: Bool {
        return set.logged || set.rpe != nil
    }

    private var rpeText: String {
        guard let rpe = set.rpeText else { return "RPE" }
        return "@\(rpe)"
    }

    private var repsChanged: Bool {
        return set.reps != set.prescribed.targetReps
    }

    private var rowOpacity: Double {
        if set.bypassed { return 0.35 }
        return 1
    }
}

private struct RPEChip: View {
    let text: String
    let hasValue: Bool
    var action: () -> Void

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(hasValue ? palette.accent : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    (hasValue ? palette.accent.opacity(0.14) : Color(uiColor: .tertiarySystemFill)),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasValue ? "Edit RPE \(text)" : "Add RPE")
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
    @FocusState private var isFocused: Bool
    private let originalLoadText: String

    init(set: LiveSet, units: Units, onChanged: @escaping () -> Void) {
        self.set = set
        self.units = units
        self.onChanged = onChanged
        let parsed = LoadControl.parse(set.load, defaultUnit: units)
        self.originalLoadText = set.load ?? "bodyweight"
        _text = State(initialValue: parsed.map { LoadControl.numberText($0.value) } ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(originalLoadText)
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)

                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                        .frame(width: 130)
                        .focused($isFocused)
                        .onChange(of: text) { _, _ in applyText() }

                    Text(units.rawValue)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("Load")
            .navigationBarTitleDisplayMode(.inline)
            .task { isFocused = true }
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

    private func reset() {
        set.load = set.prescribed.load
        text = LoadControl.parse(set.load, defaultUnit: units).map { LoadControl.numberText($0.value) } ?? ""
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

private struct RPEValueEditor: View {
    let set: LiveSet
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double

    private let values = stride(from: 1.0, through: 10.0, by: 0.5).map { $0 }

    init(set: LiveSet, onChanged: @escaping () -> Void) {
        self.set = set
        self.onChanged = onChanged
        _value = State(initialValue: set.rpe ?? 8)
    }

    var body: some View {
        NavigationStack {
            Picker("RPE", selection: Binding(
                get: { value },
                set: {
                    value = $0
                    set.rpe = $0
                    onChanged()
                }
            )) {
                ForEach(values, id: \.self) { rpe in
                    Text(LiveSet.formatRPE(rpe)).tag(rpe)
                }
            }
            .pickerStyle(.wheel)
            .navigationTitle("RPE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Remove") {
                        set.rpe = nil
                        onChanged()
                        dismiss()
                    }
                    .disabled(set.rpe == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        set.rpe = value
                        onChanged()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// All of a session's warm-up exercises shown as one compact card: each exercise gets a small
/// name label above its set rows, instead of every warm-up being its own full-height card.
struct WarmupBlockCard: View {
    let items: [LiveItem]
    let controller: WorkoutLiveController

    @State private var editingValue: SetValueEdit?
    @Environment(\.knurledPalette) private var palette

    private var units: Units { items.first?.units ?? .kg }
    private var completedCount: Int { items.filter(\.isComplete).count }
    private var allComplete: Bool { !items.isEmpty && completedCount == items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Warm Up", systemImage: "flame")
                    .font(.headline)
                Spacer()
                if allComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.accent)
                } else {
                    Text("\(completedCount)/\(items.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(items) { item in
                warmupItemSection(item)
                if item.id != items.last?.id {
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .knurledCard()
        .setEditingSheets(editingValue: $editingValue, units: units) {
            controller.modelChanged()
        }
    }

    @ViewBuilder private func warmupItemSection(_ item: LiveItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.item.display.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(item.sets.enumerated()), id: \.element.id) { _, set in
                SetRowView(
                    set: set,
                    indexLabel: "W",
                    isAmrap: false,
                    isLastSet: set.id == item.sets.last?.id,
                    isCurrent: controller.isCurrent(set),
                    onEditLoad: { editingValue = .load(set) },
                    onEditReps: { editingValue = .reps(set) },
                    onEditRPE: { editingValue = .rpe(set) },
                    onToggled: { controller.toggle(set: set, in: item) },
                    onChanged: { controller.modelChanged() }
                )
            }
        }
    }
}

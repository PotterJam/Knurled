import SwiftUI

struct LiveExerciseCard: View {
    let live: LiveItem
    let controller: WorkoutLiveController
    /// Non-nil only for exercises the user added this session, which can be removed.
    var onDelete: (() -> Void)? = nil
    var allActive: Bool = false
    @State private var showChange = false
    @State private var confirmDelete = false
    @State private var editingValue: SetValueEdit?
    @State private var completingAmrapSet: LiveSet?

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

            VStack(spacing: 0) {
                if live.hasWarmups { warmupSection }

                VStack(spacing: 0) {
                    ForEach(Array(live.sets.enumerated()), id: \.element.id) { index, set in
                        SetRowView(
                            set: set,
                            indexLabel: "\(index + 1)",
                            isAmrap: live.isAmrap,
                            isLastSet: set.id == live.lastRequiredSetID,
                            isCurrent: controller.isCurrent(set),
                            onEditLoad: { editingValue = .load(set, live) },
                            onEditReps: { editReps(for: set) },
                            onEditRPE: { editingValue = .rpe(set) },
                            onToggled: { toggle(set) },
                            onChanged: { controller.modelChanged() },
                            showsLoad: true,
                            loadMissing: !live.isBodyweight && set.load == nil,
                            isBodyweight: live.isBodyweight,
                            onDelete: set.isExtra ? {
                                withAnimation(.snappy) {
                                    live.removeSet(set)
                                    controller.modelChanged()
                                }
                            } : nil
                        )
                        .id(
                            WorkoutScrollDestination.set(
                                WorkoutScrollTarget(exerciseID: live.id, setID: set.id, isWarmup: set.isWarmup)
                            )
                        )
                        if set.id != live.sets.last?.id { Divider() }
                    }
                }
            }

            addSetRow
            footer
        }
        .knurledCard()
        .opacity(allActive || isCurrentExercise ? 1 : 0.5)
        .overlay {
            if isCurrentExercise {
                RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                    .fill(palette.accent.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        // Tapping an unfocused card jumps the cursor onto it — the way to do exercises out of
        // order (e.g. busy equipment) or to switch back to a finished one to fix or add a set.
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCurrentExercise { controller.focus(live) }
        }
        .sheet(isPresented: $showChange) {
            ChangeExerciseSheet(live: live) {
                controller.modelChanged()
            }
        }
        .sheet(item: $completingAmrapSet) { set in
            AmrapRepsEditor(set: set) { reps in
                controller.completeAmrap(set: set, in: live, reps: reps)
            }
            .presentationDetents([.height(330)])
        }
        .setEditingSheets(editingValue: $editingValue, units: live.units, controller: controller) {
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
        let visibleWarmups = live.visibleWarmups
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleWarmups.enumerated()), id: \.element.id) { _, set in
                SetRowView(
                    set: set,
                    indexLabel: "W",
                    isAmrap: false,
                    isLastSet: set.id == live.warmups.last?.id,
                    isCurrent: controller.isCurrent(set),
                    onEditLoad: { editingValue = .load(set, live) },
                    onEditReps: { editingValue = .reps(set, live) },
                    onEditRPE: { editingValue = .rpe(set) },
                    onToggled: { controller.toggle(set: set, in: live) },
                    onChanged: { controller.modelChanged() },
                    isBodyweight: live.isBodyweight
                )
                .id(
                    WorkoutScrollDestination.set(
                        WorkoutScrollTarget(exerciseID: live.id, setID: set.id, isWarmup: set.isWarmup)
                    )
                )
                if set.id != visibleWarmups.last?.id { Divider() }
            }

            Divider()
        }
    }

    private var addSetRow: some View {
        Button {
            // Adding a set to a finished exercise should put the cursor back on it, so the user
            // can do the extra set without first having to undo a completed one.
            let wasComplete = live.isComplete
            live.addSet()
            if wasComplete {
                controller.focus(live)
            } else {
                controller.modelChanged()
            }
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

    private func isPendingAmrap(_ set: LiveSet) -> Bool {
        live.isAmrap && set.id == live.lastRequiredSetID && !set.logged
    }

    private func editReps(for set: LiveSet) {
        if isPendingAmrap(set) {
            completingAmrapSet = set
        } else {
            editingValue = .reps(set, live)
        }
    }

    private func toggle(_ set: LiveSet) {
        if isPendingAmrap(set) {
            completingAmrapSet = set
            return
        }
        // A weighted set with no value yet can't be ticked — guide the user straight to the weight
        // editor instead of silently logging an empty load.
        if !set.logged, !live.isBodyweight, set.load == nil {
            editingValue = .load(set, live)
            return
        }
        controller.toggle(set: set, in: live)
    }

}

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 40
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum SetValueEdit: Identifiable {
    case load(LiveSet, LiveItem)
    case reps(LiveSet, LiveItem)
    case rpe(LiveSet)

    var id: String {
        switch self {
        case .load(let set, _): "load-\(ObjectIdentifier(set).hashValue)"
        case .reps(let set, _): "reps-\(ObjectIdentifier(set).hashValue)"
        case .rpe(let set): "rpe-\(ObjectIdentifier(set).hashValue)"
        }
    }
}

/// Hosts the load / reps / RPE editing sheets shared by the working-set card and the combined
/// warm-up block so both edit a set the same way.
private struct SetEditingSheets: ViewModifier {
    @Binding var editingValue: SetValueEdit?
    let units: Units
    let controller: WorkoutLiveController
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $editingValue) { edit in
                switch edit {
                case .load(let set, let item):
                    LoadValueEditor(set: set, item: item, units: units, onChanged: onChanged)
                        .presentationDetents([.height(250)])
                case .reps(let set, let item):
                    RepsWheelEditor(set: set, onDone: { reps in
                        controller.editReps(set: set, in: item, reps: reps)
                        onChanged()
                    })
                    .presentationDetents([.height(260)])
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
        controller: WorkoutLiveController,
        onChanged: @escaping () -> Void
    ) -> some View {
        modifier(SetEditingSheets(
            editingValue: editingValue,
            units: units,
            controller: controller,
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
            .frame(width: 24, height: 24)
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

struct SetRepsPresentation: Equatable {
    let reps: Int
    let showsAmrapMarker: Bool

    init(
        prescribedReps: Int,
        performedReps: Int,
        isAmrapFinal: Bool,
        isLogged: Bool
    ) {
        reps = isAmrapFinal && !isLogged ? prescribedReps : performedReps
        showsAmrapMarker = isAmrapFinal && !isLogged
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
    /// Whether to show the weight chip at all. On for everything now — bodyweight sets show a
    /// tappable "bw" chip so added weight (e.g. a dip belt) can be entered.
    var showsLoad: Bool = true
    /// True when a weighted set has no value yet and must be filled in before it can be ticked.
    var loadMissing: Bool = false
    /// Bodyweight exercises carry no base load; the chip reads "bw" until extra weight is added.
    var isBodyweight: Bool = false
    /// Non-nil only for user-added sets, which can be swiped away.
    var onDelete: (() -> Void)? = nil
    /// The completed "logged" band. Off when a parent (e.g. the warm-up block) paints completion at
    /// the exercise level instead, so the band isn't a skinny stripe under a separate name label.
    var showsCompletedBand: Bool = true

    @Environment(\.knurledPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
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
        return HStack(spacing: 10) {
            SetIndexBadge(label: indexLabel, isCurrent: isCurrent && !set.logged)

            prescriptionView
                .font(.subheadline.weight(isCurrent && !set.logged ? .semibold : .regular))
                .frame(maxWidth: .infinity)

            Button(action: onToggled) {
                Image(systemName: set.logged ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(set.logged ? completedForeground : .secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.logged ? "Undo set" : "Mark set done")
        }
        .frame(minHeight: 30)
        .padding(.vertical, 1)
        .background {
            if set.logged && showsCompletedBand {
                // Full-bleed band that fills the row up to the dividers and runs out to the card
                // edges, rather than a narrow inset pill.
                completedBackground
                    .padding(.horizontal, -KnurledTheme.Spacing.m)
            }
        }
        .opacity(rowOpacity)
        .animation(.snappy, value: set.logged)
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
            if showsLoad {
                ValueChip(
                    text: loadChipText,
                    isChanged: loadMissing || loadChanged,
                    truncates: true,
                    action: onEditLoad
                )
                .layoutPriority(1)
                Text("×")
                    .foregroundStyle(.secondary)
            }
            ValueChip(
                text: "\(repsPresentation.reps)\(repsPresentation.showsAmrapMarker ? "+" : "")",
                isChanged: repsChanged,
                action: onEditReps
            )
            Spacer(minLength: 6)
            if showRPEChip {
                RPEChip(text: rpeText, value: set.rpe, action: onEditRPE)
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

    private var loadChipText: String {
        if let load = set.load { return load }
        if isBodyweight { return "bw" }
        return loadMissing ? "Add weight" : "—"
    }

    private var loadChanged: Bool {
        return set.load != set.prescribed.load
    }

    private var repsPresentation: SetRepsPresentation {
        SetRepsPresentation(
            prescribedReps: set.prescribed.targetReps,
            performedReps: set.reps,
            isAmrapFinal: isAmrapFinal,
            isLogged: set.logged
        )
    }

    private var showRPEChip: Bool {
        // Warm-up sets are guidance-only ramp work — no RPE to track.
        return !set.isWarmup && (set.logged || set.rpe != nil)
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

    private var completedBackground: Color {
        // Soft sage to match the scheme, instead of the heavy dark systemGreen slab.
        Color(red: 0.55, green: 0.71, blue: 0.53).opacity(colorScheme == .dark ? 0.22 : 0.18)
    }

    private var completedForeground: Color {
        if colorScheme == .dark {
            return Color(red: 0.62, green: 0.80, blue: 0.60)
        }
        return Color(red: 0.32, green: 0.52, blue: 0.34)
    }
}

private struct RPEChip: View {
    let text: String
    let value: Double?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.monospacedDigit().weight(value == nil ? .medium : .semibold))
                .foregroundStyle(value.map(RPEColorScale.foreground) ?? Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 48)
                .padding(.vertical, 3)
                .background(
                    value.map(RPEColorScale.background) ?? Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == nil ? "Add RPE" : "Edit RPE \(text)")
    }
}

enum RPEColorScale {
    // ColorBrewer RdYlGn, reversed so effort rises from green to red.
    private static let colors: [UInt32] = [
        0x006837, 0x1A9850, 0x66BD63, 0xA6D96A, 0xD9EF8B, 0xFFFFBF,
        0xFEE08B, 0xFDAE61, 0xF46D43, 0xD73027, 0xA50026,
    ]

    static func hex(for value: Double) -> UInt32 {
        colors[paletteIndex(for: value)]
    }

    static func paletteIndex(for value: Double) -> Int {
        let normalized = (min(max(value, 1), 10) - 1) / 9
        return Int((normalized * Double(colors.count - 1)).rounded())
    }

    static func background(for value: Double) -> Color {
        color(hex(for: value))
    }

    static func foreground(for value: Double) -> Color {
        let components = rgb(hex(for: value))
        let luminance = 0.2126 * linearized(components.red)
            + 0.7152 * linearized(components.green)
            + 0.0722 * linearized(components.blue)
        return luminance > 0.179 ? .black : .white
    }

    private static func color(_ hex: UInt32) -> Color {
        let components = rgb(hex)
        return Color(red: components.red, green: components.green, blue: components.blue)
    }

    private static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    private static func linearized(_ component: Double) -> Double {
        if component <= 0.04045 { return component / 12.92 }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}

private struct ValueChip: View {
    let text: String
    let isChanged: Bool
    /// When true the chip may shrink and tail-truncate instead of forcing its full intrinsic
    /// width — used for the load, which can be a long note that would otherwise push the row
    /// off the card edge.
    var truncates: Bool = false
    var action: () -> Void

    @Environment(\.knurledPalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline.monospacedDigit().weight(isChanged ? .semibold : .medium))
                .foregroundStyle(isChanged ? .orange : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !truncates, vertical: false)
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
    let item: LiveItem
    let units: Units
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: LoadEditDraft
    @FocusState private var isFocused: Bool

    /// True when the set arrived with no weight at all — entering the first weight seeds every
    /// working set of the exercise, and we show a plain weight field rather than a "bodyweight →"
    /// transition (there was never a bodyweight value to move away from).
    private var isFirstWeight: Bool { draft.seedsWholeExercise }

    init(set: LiveSet, item: LiveItem, units: Units, onChanged: @escaping () -> Void) {
        self.set = set
        self.item = item
        self.units = units
        self.onChanged = onChanged
        let hadLoad = set.load != nil
        _draft = State(initialValue: LoadEditDraft(
            baselineText: hadLoad ? (set.load ?? "") : "",
            seedsWholeExercise: !hadLoad && !set.isWarmup
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !isFirstWeight, !draft.baselineText.isEmpty {
                        Text(draft.baselineText)
                            .font(.title3.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)

                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    TextField(isFirstWeight ? "Weight" : "New", text: $draft.destinationText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.largeTitle.monospacedDigit().weight(.semibold))
                        .frame(width: 130)
                        .focused($isFocused)
                        .onChange(of: draft.destinationText) { _, _ in applyText() }

                    Text(units.rawValue)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(isFirstWeight ? "Add weight" : "Load")
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
        if draft.seedsWholeExercise {
            item.adjust(load: set.prescribed.load, scope: .wholeExercise, from: set.id)
        } else {
            set.load = set.prescribed.load
        }
        draft = LoadEditDraft(
            baselineText: set.load ?? (set.isWarmup ? "bodyweight" : ""),
            seedsWholeExercise: draft.seedsWholeExercise
        )
        onChanged()
    }

    private func applyText() {
        draft.applyDestination(to: set, in: item, units: units)
        onChanged()
    }
}

/// Reps entry as a wheel picker, starting from the set's current reps. Tapping Done commits
/// the value and auto-logs the set when load is present, so the user doesn't need an extra tap.
struct RepsWheelEditor: View {
    let set: LiveSet
    var onDone: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reps: Int

    init(set: LiveSet, onDone: @escaping (Int) -> Void) {
        self.set = set
        self.onDone = onDone
        _reps = State(initialValue: set.reps)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Reps", selection: $reps) {
                    ForEach(0...99, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .padding(.horizontal)
            .navigationTitle("Reps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(reps)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AmrapRepsEditor: View {
    let set: LiveSet
    var onDone: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reps: Int

    init(set: LiveSet, onDone: @escaping (Int) -> Void) {
        self.set = set
        self.onDone = onDone
        _reps = State(initialValue: set.reps)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Target: \(set.prescribed.targetReps)+")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Reps performed", selection: $reps) {
                    ForEach(0...99, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .pickerStyle(.wheel)

            }
            .padding(.horizontal)
            .navigationTitle("AMRAP reps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(reps)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
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
    @State private var manuallyExpanded: Set<String> = []
    @Environment(\.knurledPalette) private var palette

    private var units: Units { items.first?.units ?? .kg }
    private var completedCount: Int { items.filter(\.isComplete).count }
    private var allComplete: Bool { !items.isEmpty && completedCount == items.count }

    /// The warm-up you're on stays open; everything else collapses to a single line so a long
    /// warm-up list doesn't dominate the screen. The user can still tap any row open.
    private func isExpanded(_ item: LiveItem) -> Bool {
        controller.isCurrentExercise(item) || manuallyExpanded.contains(item.id)
    }

    private func toggleExpanded(_ item: LiveItem) {
        if manuallyExpanded.contains(item.id) {
            manuallyExpanded.remove(item.id)
        } else {
            manuallyExpanded.insert(item.id)
        }
    }

    private func summary(_ item: LiveItem) -> String {
        let count = item.sets.count
        return "\(count) \(count == 1 ? "set" : "sets")"
    }

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
                warmupItemSection(item, isExpanded: isExpanded(item))
                if item.id != items.last?.id {
                    Divider().padding(.vertical, 2)
                }
            }
        }
        .knurledCard()
        .setEditingSheets(editingValue: $editingValue, units: units, controller: controller) {
            controller.modelChanged()
        }
    }

    @ViewBuilder private func warmupItemSection(_ item: LiveItem, isExpanded: Bool) -> some View {
        let done = item.isComplete
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { toggleExpanded(item) }
            } label: {
                HStack(spacing: 5) {
                    Text(item.item.display.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(done ? completedForeground : .secondary)
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(completedForeground)
                    }
                    Spacer(minLength: 0)
                    if !isExpanded {
                        Text(done ? "Done" : summary(item))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
            VStack(spacing: 0) {
                ForEach(Array(item.sets.enumerated()), id: \.element.id) { _, set in
                    SetRowView(
                        set: set,
                        indexLabel: "W",
                        isAmrap: false,
                        isLastSet: set.id == item.sets.last?.id,
                        isCurrent: controller.isCurrent(set),
                        onEditLoad: { editingValue = .load(set, item) },
                        onEditReps: { editingValue = .reps(set, item) },
                        onEditRPE: { editingValue = .rpe(set) },
                        onToggled: { controller.toggle(set: set, in: item) },
                        onChanged: { controller.modelChanged() },
                        isBodyweight: item.isBodyweight,
                        showsCompletedBand: false
                    )
                    .id(
                        WorkoutScrollDestination.set(
                            WorkoutScrollTarget(exerciseID: item.id, setID: set.id, isWarmup: set.isWarmup)
                        )
                    )
                    if set.id != item.sets.last?.id { Divider() }
                }
            }
            }
        }
        // The whole exercise — name and its sets — turns sage when done, instead of a thin band
        // under just the set rows. Keep it vertically flush with its content and full-bleed to the
        // card edges to match the working-set treatment.
        .padding(.horizontal, KnurledTheme.Spacing.m)
        .background {
            if done {
                Color(red: 0.55, green: 0.71, blue: 0.53).opacity(0.16)
            }
        }
        .padding(.horizontal, -KnurledTheme.Spacing.m)
        .id(WorkoutScrollDestination.exercise(item.id))
    }

    private var completedForeground: Color {
        Color(red: 0.40, green: 0.58, blue: 0.40)
    }
}

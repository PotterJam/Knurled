import SwiftUI
import UniformTypeIdentifiers

struct ActiveWorkoutView: View {
    @State private var workout: LiveWorkout
    @State private var showFinish = false
    @State private var showAddExercise = false
    @State private var showLeaveDialog = false
    @State private var showDiscardConfirm = false
    @State private var draggingItemID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingScroll: Task<Void, Never>?
    @State private var restTarget: LiveItem?
    @State private var showRepsEditor = false
    @State private var undoableDelete: UndoableDelete?

    private let resumeDraft: WorkoutDraft?
    private let controller = WorkoutLiveController.shared

    @Environment(AppModel.self) private var app
    @Environment(WorkoutSettings.self) private var workoutSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(repo: ActiveRepo, session: RenderedSession, restoring record: TrainingRecord? = nil) {
        _workout = State(initialValue: LiveWorkout(repo: repo, session: session, restoring: record))
        self.resumeDraft = nil
    }

    init(repo: ActiveRepo, session: RenderedSession, draft: WorkoutDraft) {
        _workout = State(initialValue: LiveWorkout(repo: repo, session: session, draft: draft))
        self.resumeDraft = draft
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: KnurledTheme.Spacing.s) {
                    progress
                    if !warmupItems.isEmpty {
                        WarmupBlockCard(items: warmupItems, controller: controller)
                    }
                    ForEach(bodyItems) { item in
                        LiveExerciseCard(
                            live: item,
                            controller: controller,
                            onDelete: item.isTrackingOnlyExtra ? {
                                let index = workout.items.firstIndex { $0.id == item.id }
                                    ?? workout.items.endIndex
                                withAnimation(.snappy) {
                                    workout.removeItem(item)
                                    controller.modelChanged()
                                }
                                offerUndo("\(item.item.display.title) removed") {
                                    workout.restoreItem(item, at: index)
                                }
                            } : nil,
                            onUndoableDelete: { message, restore in
                                offerUndo(message, restore: restore)
                            }
                        )
                            .id(WorkoutScrollDestination.exercise(item.id))
                            .onDrag {
                                draggingItemID = item.id
                                return NSItemProvider(object: item.id as NSString)
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: ExerciseDropDelegate(
                                    target: item,
                                    workout: workout,
                                    draggingItemID: $draggingItemID
                                )
                            )
                    }
                    addExerciseRow
                }
                .padding()
                // Fallback so releasing a drag anywhere clears the dragging state and nothing
                // gets left in a half-dragged look.
                .onDrop(of: [.plainText], delegate: ResetDragDelegate(draggingItemID: $draggingItemID))
            }
            .safeAreaInset(edge: .top) {
                jumpStrip(proxy: proxy)
            }
            .onAppear {
                controller.begin(workout, restTimersEnabled: workoutSettings.restTimersEnabled, resumingFrom: resumeDraft)
                if let target = controller.currentScrollTarget {
                    proxy.scrollTo(WorkoutScrollDestination.exercise(target.exerciseID), anchor: .top)
                }
                // The Live Activity's "Log set" may have opened the app before this screen
                // appeared — honour any pending request to edit reps on the current set.
                if controller.pendingRepsEdit { openRepsEditor() }
                // Starting the workout commits to it: flush any locally-skipped cursor to GitHub
                // now, in the background, rather than on every skip tap.
                Task { await app.syncPendingChanges(in: workout.repo) }
            }
            .onDisappear {
                pendingScroll?.cancel()
                // Flush any debounced draft save before tearing down, so leaving mid-edit keeps
                // the latest state. After a discard the workout is already gone and this no-ops.
                controller.persistDraftNow()
                controller.end()
            }
            .onChange(of: workoutSettings.restTimersEnabled) { _, enabled in
                controller.setRestTimersEnabled(enabled)
            }
            .onChange(of: controller.currentScrollTarget) { previous, current in
                guard let previous, let current else { return }
                scroll(
                    WorkoutScrollRequest.afterAdvance(from: previous, to: current),
                    proxy: proxy
                )
            }
            .onChange(of: controller.pendingRepsEdit) { _, pending in
                if pending { openRepsEditor() }
            }
        }
        .navigationTitle(workout.session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    leave()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.persistDraftNow() }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let undoableDelete {
                    UndoToast(message: undoableDelete.message) {
                        undoableDelete.restore()
                        controller.modelChanged()
                        self.undoableDelete = nil
                    }
                }
                RestTimerBar(controller: controller) {
                    restTarget = controller.currentTarget?.item
                }
                    .animation(.snappy, value: controller.isResting)
                bottomBar
            }
            .animation(.snappy, value: undoableDelete?.id)
        }
        .task(id: undoableDelete?.id) {
            guard undoableDelete != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { undoableDelete = nil }
        }
        .confirmationDialog("Leave workout?", isPresented: $showLeaveDialog, titleVisibility: .visible) {
            Button("Pause & leave") { dismiss() }
            Button("Discard workout", role: .destructive) { controller.discard(); dismiss() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Your progress is saved automatically — you can resume right where you left off.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) { controller.discard(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your in-progress workout. This can't be undone.")
        }
        .sheet(isPresented: $showFinish) {
            FinishWorkoutView(workout: workout) { dismiss() }
        }
        .sheet(isPresented: $showAddExercise) {
            AddExerciseSheet(repo: workout.repo, catalog: app.exerciseCatalog) { exercise, load, sets, reps in
                let item = workout.addExtraExercise(exercise: exercise, load: load, setCount: sets, reps: reps)
                controller.focus(item)
                controller.modelChanged()
            }
        }
        .sheet(isPresented: $showRepsEditor) {
            if let (item, set) = controller.currentTarget {
                RepsWheelEditor(set: set, onDone: { reps in
                    controller.editReps(set: set, in: item, reps: reps)
                })
                .presentationDetents([.height(260)])
            }
        }
        .sheet(item: $restTarget) { item in
            SessionRestEditor(item: item, plan: workout.repo.plan) { seconds, saveToProgram in
                item.restSeconds = seconds
                if controller.isResting {
                    controller.addRest(seconds - Int(controller.remaining.rounded(.up)))
                }
                guard saveToProgram else { return }
                var policy = workout.repo.plan?.rest ?? RestPolicy()
                policy.byExercise[LiveItem.normalized(item.performedExercise ?? item.item.exercise)] = seconds
                Task {
                    do {
                        _ = try await app.applyPlanEdit(
                            .quick(QuickPlanEdit(
                                suggestedDays: nil,
                                equipment: nil,
                                customExercise: nil,
                                accessory: nil,
                                sessionExercises: nil,
                                rest: policy
                            )),
                            in: workout.repo,
                            message: "Update exercise rest"
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        .alert("Couldn't save", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var warmupItems: [LiveItem] { workout.items.filter(\.isSessionWarmup) }
    private var bodyItems: [LiveItem] { workout.items.filter { !$0.isSessionWarmup } }

    /// A pinned horizontal strip of the session's exercises for quick jumping. Tapping scrolls to
    /// an exercise and, unless it's already done, moves the cursor onto it.
    @ViewBuilder private func jumpStrip(proxy: ScrollViewProxy) -> some View {
        if bodyItems.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bodyItems) { item in
                        jumpPill(item, proxy: proxy)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }

    private func jumpPill(_ item: LiveItem, proxy: ScrollViewProxy) -> some View {
        let isCurrent = controller.isCurrentExercise(item)
        let done = item.isComplete
        return Button {
            withAnimation(.snappy) {
                proxy.scrollTo(WorkoutScrollDestination.exercise(item.id), anchor: .top)
            }
            // Focus whatever the user taps — including a finished exercise they're going back to.
            controller.focus(item)
        } label: {
            HStack(spacing: 4) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(item.item.display.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(pillBackground(isCurrent: isCurrent, done: done), in: Capsule())
            .foregroundStyle(pillForeground(isCurrent: isCurrent, done: done))
        }
        .buttonStyle(.plain)
    }

    private func pillBackground(isCurrent: Bool, done: Bool) -> Color {
        if isCurrent { return .accentColor }
        if done { return Color.green.opacity(0.18) }
        return Color(uiColor: .tertiarySystemFill)
    }

    private func pillForeground(isCurrent: Bool, done: Bool) -> Color {
        if isCurrent { return .white }
        if done { return Color.green }
        return .secondary
    }

    /// Present the reps editor on the current set in response to the Live Activity's "Log set"
    /// action, then clear the request so a later tap can raise it again.
    private func openRepsEditor() {
        controller.clearRepsEditRequest()
        guard controller.currentTarget != nil else { return }
        showRepsEditor = true
    }

    private func scroll(_ request: WorkoutScrollRequest, proxy: ScrollViewProxy) {
        pendingScroll?.cancel()
        if request.delayForLayout {
            pendingScroll = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(request.destination, anchor: .center)
                }
            }
        } else {
            withAnimation(.snappy) {
                proxy.scrollTo(request.destination, anchor: .center)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(workout.completedRequiredCount) of \(workout.requiredItems.count) exercises completed")
                .font(.subheadline.weight(.medium))
            ProgressView(
                value: Double(workout.completedRequiredCount),
                total: Double(max(workout.requiredItems.count, 1))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addExerciseRow: some View {
        Button {
            showAddExercise = true
        } label: {
            Label("Add exercise", systemImage: "plus.circle")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KnurledTheme.Radius.card, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(.secondary.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: KnurledTheme.Spacing.m) {
            Button {
                showFinish = true
            } label: {
                Label("Finish", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // Finishing is allowed as soon as anything is logged. The record contains exactly the
            // work performed; only fully completed exercises progress.
            .disabled(!workout.canSubmit || isSaving)

            Menu {
                Button("Discard workout", systemImage: "trash", role: .destructive) {
                    showDiscardConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
            }
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    /// Progress is auto-saved, so leaving never loses data. Prompt only when something is logged
    /// so the user can choose to keep the draft (pause) or drop it; an empty workout just exits.
    private func leave() {
        if workout.anyLogged {
            showLeaveDialog = true
        } else {
            controller.discard()
            dismiss()
        }
    }

    private func offerUndo(_ message: String, restore: @escaping () -> Void) {
        undoableDelete = UndoableDelete(message: message, restore: restore)
    }
}

/// A just-deleted set or exercise, held briefly so the user can take the deletion back.
private struct UndoableDelete: Identifiable {
    let id = UUID()
    let message: String
    let restore: () -> Void
}

private struct UndoToast: View {
    let message: String
    var onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct SessionRestEditor: View {
    let item: LiveItem
    let plan: PlanIR?
    var onSave: (Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Int
    @State private var saveToProgram = false

    init(item: LiveItem, plan: PlanIR?, onSave: @escaping (Int, Bool) -> Void) {
        self.item = item
        self.plan = plan
        self.onSave = onSave
        _seconds = State(initialValue: item.restSeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("This workout") {
                    Stepper("\(seconds / 60)m \(seconds % 60)s", value: $seconds, in: 15...600, step: 15)
                }
                Section {
                    Toggle("Save for this exercise", isOn: $saveToProgram)
                } footer: {
                    Text("Saving updates the program; otherwise this applies only to the current workout.")
                }
            }
            .navigationTitle("Rest after \(item.performedExerciseName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onSave(seconds, saveToProgram); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ExerciseDropDelegate: DropDelegate {
    let target: LiveItem
    let workout: LiveWorkout
    @Binding var draggingItemID: String?

    func dropEntered(info: DropInfo) {
        guard let draggingItemID else { return }
        workout.moveItem(from: draggingItemID, before: target.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropExited(info: DropInfo) {}

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Catches drops that land between cards (or outside any card) so the dragging state is always
/// cleared — otherwise a drag that ends on empty space would leave it stuck.
private struct ResetDragDelegate: DropDelegate {
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

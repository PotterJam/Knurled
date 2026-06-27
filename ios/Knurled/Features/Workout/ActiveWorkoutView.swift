import SwiftUI
import UniformTypeIdentifiers

struct ActiveWorkoutView: View {
    @State private var workout: LiveWorkout
    @State private var showFinish = false
    @State private var showAddExercise = false
    @State private var draggingItemID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingScroll: Task<Void, Never>?

    private let controller = WorkoutLiveController.shared

    @Environment(AppModel.self) private var app
    @Environment(WorkoutSettings.self) private var workoutSettings
    @Environment(\.dismiss) private var dismiss

    init(repo: ActiveRepo, session: RenderedSession, restoring record: DayRecord? = nil) {
        _workout = State(initialValue: LiveWorkout(repo: repo, session: session, restoring: record))
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
                                withAnimation(.snappy) {
                                    workout.removeItem(item)
                                    controller.modelChanged()
                                }
                            } : nil
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
            .onAppear {
                controller.begin(workout, restTimersEnabled: workoutSettings.restTimersEnabled)
                if let target = controller.currentScrollTarget {
                    proxy.scrollTo(WorkoutScrollDestination.exercise(target.exerciseID), anchor: .top)
                }
            }
            .onDisappear {
                pendingScroll?.cancel()
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
        }
        .navigationTitle(workout.session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                RestTimerBar(controller: controller)
                    .animation(.snappy, value: controller.isResting)
                bottomBar
            }
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
        .alert("Couldn't save", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var warmupItems: [LiveItem] { workout.items.filter(\.isSessionWarmup) }
    private var bodyItems: [LiveItem] { workout.items.filter { !$0.isSessionWarmup } }

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
                Label(submitTitle, systemImage: submitIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!workout.canSubmit || isSaving)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private var submitTitle: String {
        workout.canSaveProgress ? "Save Progress" : "Finish"
    }

    private var submitIcon: String {
        workout.canSaveProgress ? "tray.and.arrow.down.fill" : "flag.checkered"
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

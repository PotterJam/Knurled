import SwiftUI
import UniformTypeIdentifiers

struct ActiveWorkoutView: View {
    @State private var workout: LiveWorkout
    @State private var showFinish = false
    @State private var showAddExercise = false
    @State private var draggingItemID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let controller = WorkoutLiveController.shared

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(repo: ActiveRepo, session: RenderedSession, restoring record: DayRecord? = nil) {
        _workout = State(initialValue: LiveWorkout(repo: repo, session: session, restoring: record))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: KnurledTheme.Spacing.m) {
                    progress
                    ForEach(workout.items) { item in
                        LiveExerciseCard(
                            live: item,
                            controller: controller,
                            isCollapsedForDrag: draggingItemID != nil && draggingItemID != item.id
                        )
                            .id(item.id)
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
            }
            .onAppear {
                controller.begin(workout)
                scrollToExercise(currentExerciseID, proxy: proxy, animated: false)
            }
            .onDisappear { controller.end() }
            .onChange(of: currentExerciseID) { _, exerciseID in
                scrollToExercise(exerciseID, proxy: proxy)
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

    private var currentExerciseID: String? {
        controller.currentTarget?.item.id
    }

    private func scrollToExercise(_ exerciseID: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let exerciseID else { return }
        if animated {
            withAnimation(.snappy) {
                proxy.scrollTo(exerciseID, anchor: .top)
            }
        } else {
            proxy.scrollTo(exerciseID, anchor: .top)
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

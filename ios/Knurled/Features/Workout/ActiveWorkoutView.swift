import SwiftUI

struct ActiveWorkoutView: View {
    @State private var workout: LiveWorkout
    @State private var showFinish = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let controller = WorkoutLiveController.shared

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(repo: ActiveRepo, session: RenderedSession, resuming: TrainingEvent? = nil) {
        _workout = State(initialValue: LiveWorkout(repo: repo, session: session, resuming: resuming))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: KnurledTheme.Spacing.m) {
                progress
                ForEach(workout.items) { item in
                    LiveExerciseCard(live: item, controller: controller)
                }
            }
            .padding()
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
        .onAppear { controller.begin(workout) }
        .onDisappear { controller.end() }
        .sheet(isPresented: $showFinish) {
            FinishWorkoutView(workout: workout) { dismiss() }
        }
        .alert("Couldn't save", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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

    private var bottomBar: some View {
        HStack(spacing: KnurledTheme.Spacing.m) {
            Button {
                Task { await savePartial() }
            } label: {
                Label("Pause / Save", systemImage: "pause.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!workout.anyLogged || isSaving)

            Button {
                showFinish = true
            } label: {
                Label("Finish", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!workout.canFinish || isSaving)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private func savePartial() async {
        isSaving = true
        defer { isSaving = false }
        let timestamp = LiveWorkout.timestamp()
        let input = workout.executionInput(status: ExecutionStatus.partial, timestamp: timestamp)
        guard !input.inputs.isEmpty else { dismiss(); return }
        do {
            let outcome = try await app.engine.reduce(dir: workout.repo.url, session: workout.session, input: input)
            try await app.commit(outcome: outcome, in: workout.repo, timestamp: timestamp)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

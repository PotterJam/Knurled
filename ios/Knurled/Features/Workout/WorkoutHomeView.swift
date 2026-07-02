import SwiftUI

struct WorkoutHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Workout")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        if let repo = app.activeRepo, let session = repo.nextWorkout {
            NextWorkoutView(repo: repo, session: session)
        } else if app.phase == .launching {
            ProgressView("Loading…")
        } else {
            ContentUnavailableView {
                Label("No Workout", systemImage: "dumbbell.fill")
            } description: {
                Text("Your program has no next workout. Check your plan, or restore a backup from Settings.")
            }
        }
    }
}

struct NextWorkoutView: View {
    let repo: ActiveRepo
    let session: RenderedSession
    @Environment(AppModel.self) private var app
    @Environment(DraftStore.self) private var draftStore
    @State private var isSyncing = false
    @State private var isSkipping = false
    @State private var skipError: String?
    @State private var draft: WorkoutDraft?
    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top])
                .padding(.bottom, KnurledTheme.Spacing.s)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: KnurledTheme.Spacing.m) {
                    ForEach(previewItems) { item in
                        ExercisePrescriptionCard(item: item)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }

            startBar
        }
        .refreshable { await app.sync() }
        .onAppear { reloadDraft() }
        .onChange(of: draftStore.hasDraft) { _, _ in
            reloadDraft()
        }
        .toolbar {
            if let plan = repo.plan {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        PlanOverviewView(repo: repo, plan: plan)
                            .navigationTitle("Plan")
                    } label: {
                        Label(plan.plan.name, systemImage: "doc.text")
                    }
                    .accessibilityHint("Opens the plan overview")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { isSyncing = true; await app.sync(); isSyncing = false }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isSyncing)
                .accessibilityLabel("Sync")
            }
        }
    }

    @ViewBuilder private var startBar: some View {
        VStack(spacing: KnurledTheme.Spacing.s) {
            if let draft, draft.renderedSessionHash == session.renderedSessionHash {
                NavigationLink {
                    ActiveWorkoutView(repo: repo, session: session, draft: draft)
                } label: {
                    Label("Continue Workout", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Resuming where you left off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if let draft {
                // An unfinished workout from another session blocks starting a new one: finish or
                // discard it first, so there's only ever one workout in progress.
                NavigationLink {
                    ResumeWorkoutView(repo: repo, draft: draft)
                } label: {
                    Label("Continue \(draft.displayName)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    showDiscardConfirm = true
                } label: {
                    Label("Discard & start \(session.displayName)", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .confirmationDialog(
                    "Discard \(draft.displayName)?",
                    isPresented: $showDiscardConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Discard workout", role: .destructive) {
                        draftStore.clear()
                        self.draft = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the sets you already logged in \(draft.displayName). This can't be undone.")
                }

                Text("Finish or discard your in-progress workout before starting a new one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                NavigationLink {
                    ActiveWorkoutView(repo: repo, session: session)
                } label: {
                    Label("Start Workout", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Your progress saves automatically as you log sets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.bar)
    }

    private var previewItems: [RenderedItem] {
        session.items.filter { $0.phase == .main }
    }

    private var header: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: KnurledTheme.Spacing.s) {
                skipButton(forward: false, systemImage: "chevron.left", label: "Previous workout")

                VStack(alignment: .center, spacing: 6) {
                    Text(session.displayName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if let day = WorkoutFormat.relativeDay(fromISO: session.suggestedDate) {
                        Text("Suggested: \(day)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                skipButton(forward: true, systemImage: "chevron.right", label: "Skip to next workout")
            }

            if let rotation = repo.plan?.schedule.rotation, !rotation.isEmpty {
                RotationIndicator(rotation: rotation, currentSession: session.sessionId)
                    .padding(.vertical, 4)
            }

            if let skipError {
                Text(skipError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                if repo.isValid {
                    StatusChip(text: "Plan valid", style: .ok)
                } else {
                    StatusChip(text: "Plan invalid", style: .bad)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func skipButton(forward: Bool, systemImage: String, label: String) -> some View {
        Button {
            skip(forward: forward)
        } label: {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .disabled(isSkipping)
        .accessibilityLabel(label)
    }

    private func skip(forward: Bool) {
        skipError = nil
        Task {
            isSkipping = true
            defer { isSkipping = false }
            do {
                try await app.skipWorkout(forward: forward, in: repo)
                // The cursor moved, so any in-progress draft no longer matches the workout on
                // screen; reload so the start bar reflects the freshly selected session.
                reloadDraft()
            } catch {
                skipError = error.localizedDescription
            }
        }
    }

    private func reloadDraft() {
        draft = draftStore.hasDraft ? draftStore.loadUncommitted(records: repo.records) : nil
    }
}

struct ExercisePrescriptionCard: View {
    let item: RenderedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.display.title)
                    .font(.headline)
                Spacer()
                if let tier = WorkoutFormat.tier(fromLane: item.progressionLane) {
                    TierBadge(tier: tier)
                }
            }

            Text(item.display.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(WorkoutFormat.repScheme(item.prescription.sets), systemImage: "repeat")
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
        }
        .knurledCard()
    }
}

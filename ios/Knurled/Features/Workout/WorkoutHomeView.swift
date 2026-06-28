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
                Text("Connect a repository in Settings to see your next workout.")
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
    @State private var draft: WorkoutDraft?

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
        .onAppear { draft = draftStore.hasDraft ? draftStore.load() : nil }
        .onChange(of: draftStore.hasDraft) { _, _ in
            draft = draftStore.hasDraft ? draftStore.load() : nil
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
                    draftStore.clear()
                    self.draft = nil
                } label: {
                    Label("Discard & start \(session.displayName)", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

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

                Text("Finish a workout as advance, off-day, or reset when you submit it.")
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
            Text(session.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)

            if let day = WorkoutFormat.relativeDay(fromISO: session.suggestedDate) {
                Text("Suggested: \(day)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if repo.isValid {
                    StatusChip(text: "Plan valid", style: .ok)
                } else {
                    StatusChip(text: "Plan invalid", style: .bad)
                }
                if repo.isSample {
                    StatusChip(text: "Sample", style: .neutral)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
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

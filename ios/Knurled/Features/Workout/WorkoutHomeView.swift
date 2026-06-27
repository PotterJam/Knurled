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
    @State private var isSyncing = false

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

            VStack(spacing: KnurledTheme.Spacing.s) {
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
            .padding()
            .background(.bar)
        }
        .refreshable { await app.sync() }
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

    private var previewItems: [RenderedItem] {
        session.items.filter { $0.phase == .main }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayName)
                .font(.title2.bold())

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

import SwiftUI

struct WorkoutHomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Workout")
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
    @State private var showSkip = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.m) {
                header

                ForEach(session.items) { item in
                    ExercisePrescriptionCard(item: item)
                }

                NavigationLink {
                    ActiveWorkoutView(repo: repo, session: session)
                } label: {
                    Label("Start Workout", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, KnurledTheme.Spacing.s)

                Button {
                    showSkip = true
                } label: {
                    Label("Skip this workout", systemImage: "forward.end")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.secondary)

                Text("Completed this already? Open any workout from History to edit or continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding()
        }
        .refreshable { await app.refresh() }
        .sheet(isPresented: $showSkip) {
            SkipWorkoutSheet(repo: repo, session: session)
        }
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

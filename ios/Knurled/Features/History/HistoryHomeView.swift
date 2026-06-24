import SwiftUI

struct HistoryHomeView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: HistoryFilter = .all

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, KnurledTheme.Spacing.s)

                listContent
            }
            .navigationTitle("History")
        }
    }

    @ViewBuilder private var listContent: some View {
        let items = filteredItems
        if items.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "clock.arrow.circlepath",
                description: Text("Saved, partial, and skipped workouts will appear here.")
            )
        } else {
            List(items) { item in
                row(for: item)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func row(for item: HistoryItem) -> some View {
        if let repo = app.activeRepo, let session = continuableSession(for: item, in: repo) {
            NavigationLink {
                ActiveWorkoutView(repo: repo, session: session, resuming: item.event)
            } label: {
                HistoryRow(item: item)
            }
        } else if item.isCorrectable, let repo = app.activeRepo {
            NavigationLink {
                HistoryDetailView(repo: repo, event: item.event)
            } label: {
                HistoryRow(item: item)
            }
        } else {
            HistoryRow(item: item)
        }
    }

    /// A saved partial advances the cursor to the next workout, but stays resumable from history.
    /// The engine re-renders each outstanding partial (`resumableSessions`); we match by the
    /// snapshot hash it was logged against. If the plan has since changed the hash no longer
    /// matches, so it falls back to correction instead.
    private func continuableSession(for item: HistoryItem, in repo: ActiveRepo) -> RenderedSession? {
        guard item.event.type == "session_saved", item.canContinue else { return nil }
        return repo.resumableSessions.first {
            $0.renderedSessionHash == item.event.renderedSessionHash
        }
    }

    private var filteredItems: [HistoryItem] {
        let all = HistoryBuilder.items(from: app.activeRepo?.events ?? [])
        switch filter {
        case .all: return all
        case .workouts: return all.filter { $0.kind == .workout }
        case .skips: return all.filter { $0.kind == .skip }
        }
    }
}

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
                if item.isCorrectable, let repo = app.activeRepo {
                    NavigationLink {
                        HistoryDetailView(repo: repo, event: item.event)
                    } label: {
                        HistoryRow(item: item)
                    }
                } else {
                    HistoryRow(item: item)
                }
            }
            .listStyle(.plain)
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

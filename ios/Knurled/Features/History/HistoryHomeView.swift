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
                description: Text("Recorded workout days will appear here.")
            )
        } else {
            List(items) { item in
                NavigationLink {
                    HistoryDetailView(item: item)
                } label: {
                    HistoryRow(item: item)
                }
            }
            .listStyle(.plain)
        }
    }

    private var filteredItems: [HistoryItem] {
        let all = HistoryBuilder.items(from: app.activeRepo?.records ?? [])
        switch filter {
        case .all: return all
        case .workouts: return all.filter { $0.kind == .workout }
        case .programs: return all.filter { $0.kind == .program }
        }
    }
}

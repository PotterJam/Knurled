import SwiftUI

enum HistoryFilter: CaseIterable, Hashable {
    case all
    case workouts
    case programs

    var title: String {
        switch self {
        case .all: "All"
        case .workouts: "Workouts"
        case .programs: "Programs"
        }
    }
}

struct HistoryItem: Identifiable, Hashable {
    enum Kind { case workout, program }

    let id: String
    let title: String
    let detail: String
    let status: String
    let statusStyle: StatusChip.Style
    let kind: Kind
    let record: DayRecord

    var canContinue: Bool {
        record.status == ExecutionStatus.partial && record.sessionId != nil
    }
}

enum HistoryBuilder {
    static func items(from records: [DayRecord]) -> [HistoryItem] {
        records
            .sorted { $0.date < $1.date }
            .compactMap(item(from:))
            .reversed()
    }

    private static func item(from record: DayRecord) -> HistoryItem? {
        let date = WorkoutFormat.relativeDay(fromISO: record.date) ?? record.date
        if !record.lifts.isEmpty {
            let isPartial = record.status == ExecutionStatus.partial
            return HistoryItem(
                id: record.id,
                title: title(for: record),
                detail: detail(for: record, date: date),
                status: isPartial ? "Partial" : "Recorded",
                statusStyle: isPartial ? .warn : .ok,
                kind: .workout,
                record: record
            )
        }
        if let program = record.program {
            return HistoryItem(
                id: record.id,
                title: program,
                detail: date,
                status: "Program",
                statusStyle: .neutral,
                kind: .program,
                record: record
            )
        }
        return nil
    }

    private static func title(for record: DayRecord) -> String {
        if record.lifts.count == 1, let lift = record.lifts.first {
            return lift.exercise.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(record.lifts.count) lifts"
    }

    private static func detail(for record: DayRecord, date: String) -> String {
        let names = record.lifts
            .prefix(3)
            .map { $0.exercise.replacingOccurrences(of: "_", with: " ").capitalized }
            .joined(separator: ", ")
        return [date, names].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusChip(text: item.status, style: item.statusStyle)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryDetailView: View {
    let item: HistoryItem

    var body: some View {
        List {
            if item.canContinue {
                Section {
                    NavigationLink {
                        ContinueWorkoutView(record: item.record)
                    } label: {
                        Label("Continue Workout", systemImage: "play.fill")
                    }
                }
            }

            Section {
                LabeledContent("Date", value: WorkoutFormat.relativeDay(fromISO: item.record.date) ?? item.record.date)
                LabeledContent("Type", value: item.kind == .workout ? "Workout" : "Program")
                if let sessionId = item.record.sessionId {
                    LabeledContent("Session", value: sessionId.uppercased())
                }
                if let program = item.record.program {
                    LabeledContent("Program", value: program)
                }
                if let note = item.record.note {
                    Text(note)
                }
            }

            if !item.record.lifts.isEmpty {
                Section("Lifts") {
                    ForEach(item.record.lifts) { lift in
                        HistoryLiftRow(lift: lift)
                    }
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ContinueWorkoutView: View {
    let record: DayRecord

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(RenderedSession)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading workout…")
            case .loaded(let session):
                if let repo = app.activeRepo {
                    ActiveWorkoutView(repo: repo, session: session, restoring: record)
                } else {
                    ContentUnavailableView("No Repository", systemImage: "folder.badge.questionmark")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't continue", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard case .loading = phase else { return }
        guard let repo = app.activeRepo else {
            phase = .failed("Connect a repository before continuing a workout.")
            return
        }
        guard let sessionId = record.sessionId else {
            phase = .failed("This record does not include a session id.")
            return
        }

        do {
            phase = .loaded(try await app.engine.renderSession(dir: repo.url, sessionId: sessionId))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct HistoryLiftRow: View {
    let lift: LiftRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if let weight = lift.weight {
                    Text(weight)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if !lift.sets.isEmpty {
                Label(lift.sets.map(String.init).joined(separator: " / "), systemImage: "repeat")
                    .font(.callout.monospaced())
            }

            if !lift.metrics.isEmpty {
                Text(metrics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = lift.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var title: String {
        lift.exercise.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var metrics: String {
        lift.metrics
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }
}

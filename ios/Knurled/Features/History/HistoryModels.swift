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
            return HistoryItem(
                id: record.date,
                title: title(for: record),
                detail: detail(for: record, date: date),
                status: "Recorded",
                statusStyle: .ok,
                kind: .workout,
                record: record
            )
        }
        if let program = record.program {
            return HistoryItem(
                id: record.date,
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

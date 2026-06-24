import SwiftUI

enum HistoryFilter: CaseIterable, Hashable {
    case all
    case workouts
    case skips

    var title: String {
        switch self {
        case .all: "All"
        case .workouts: "Workouts"
        case .skips: "Skips"
        }
    }
}

struct HistoryItem: Identifiable, Hashable {
    enum Kind { case workout, skip }

    let id: String
    let title: String
    let detail: String
    let status: String
    let statusStyle: StatusChip.Style
    let kind: Kind
    let canContinue: Bool
    let event: TrainingEvent

    /// Only completed/saved sessions carry editable per-set results (§20).
    var isCorrectable: Bool { kind == .workout && !event.workoutResults.isEmpty }
}

enum HistoryBuilder {
    static func items(from events: [TrainingEvent]) -> [HistoryItem] {
        let corrected = Set(events.compactMap(\.correctsEventId))
        let continued = Set(events.compactMap(\.continuesEventId))
        return events.compactMap { item(from: $0, corrected: corrected, continued: continued) }.reversed()
    }

    private static func item(
        from event: TrainingEvent,
        corrected: Set<String>,
        continued: Set<String>
    ) -> HistoryItem? {
        let title = (event.sessionId ?? "Session").uppercased()
        let date = WorkoutFormat.relativeDay(
            fromISO: event.completedAt ?? event.savedAt ?? event.startedAt
        ) ?? ""
        let editedSuffix = corrected.contains(event.id) ? " · edited" : ""

        switch event.type {
        case "session_completed", "session_continued":
            return HistoryItem(
                id: event.id, title: title, detail: date + editedSuffix,
                status: "Complete", statusStyle: .ok, kind: .workout, canContinue: true,
                event: event
            )
        case "session_imported":
            let source = (event.program ?? "")
                .replacingOccurrences(of: "history_import:", with: "")
                .replacingOccurrences(of: "_", with: " ")
            return HistoryItem(
                id: event.id,
                title: event.reason ?? title,
                detail: [date, source.isEmpty ? "" : source.capitalized]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ") + editedSuffix,
                status: "Imported", statusStyle: .neutral, kind: .workout, canContinue: false,
                event: event
            )
        case "session_saved":
            // A partial that's since been continued is superseded by its continuation; that
            // continuation is the canonical row, so drop the partial instead of showing both (§19).
            if continued.contains(event.id) { return nil }
            let logged = event.workoutResults.count
            return HistoryItem(
                id: event.id, title: title,
                detail: "\(date) · \(logged) logged" + editedSuffix,
                status: (event.status ?? "partial").capitalized,
                statusStyle: .warn, kind: .workout, canContinue: true,
                event: event
            )
        case "session_skipped":
            let policy = (event.policy ?? "").replacingOccurrences(of: "_", with: " ")
            return HistoryItem(
                id: event.id, title: title, detail: [date, policy].filter { !$0.isEmpty }.joined(separator: " · "),
                status: "Skipped", statusStyle: .neutral, kind: .skip, canContinue: false,
                event: event
            )
        default:
            return nil
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                if item.canContinue && item.status != "Complete" {
                    Text("Can continue")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer()
            StatusChip(text: item.status, style: item.statusStyle)
        }
        .padding(.vertical, 2)
    }
}

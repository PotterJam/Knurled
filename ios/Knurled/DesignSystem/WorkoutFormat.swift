import Foundation

enum WorkoutFormat {
    static func repScheme(_ sets: [PrescribedSet]) -> String {
        sets
            .map { "\($0.targetReps)\($0.amrap ? "+" : "")" }
            .joined(separator: " / ")
    }

    static func actualScheme(_ sets: [ActualSet]) -> String {
        sets.map { String($0.reps) }.joined(separator: " / ")
    }

    static func tier(fromLane lane: String) -> String? {
        lane.split(separator: ".").last.map(String.init)
    }

    static func effectSummary(_ effect: Effect) -> String {
        switch effect.op {
        case "increase_load", "decrease_load":
            if let from = effect.from, let to = effect.to { return "\(from) → \(to)" }
            return effect.to ?? effect.op
        case "advance_stage", "reset_stage":
            if let from = effect.from, let to = effect.to { return "\(from) → \(to)" }
            return effect.to ?? effect.op
        default:
            if let from = effect.from, let to = effect.to { return "\(from) → \(to)" }
            return effect.to ?? effect.op
        }
    }

    static func laneTitle(_ lane: String) -> String {
        lane
            .split(separator: ".")
            .map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
            .joined(separator: " ")
    }

    static func relativeDay(fromISO iso: String?) -> String? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            return String(iso.prefix(10))
        }
        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d"
        return display.string(from: date)
    }
}

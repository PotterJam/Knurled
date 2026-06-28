import Foundation
import Observation

/// A crash-safe snapshot of an in-progress workout. Unlike a committed `TrainingRecord`,
/// a draft captures the *full* live state — including unlogged loads/reps, bypassed warmups,
/// RPE, and the cursor — so a workout interrupted by a force-quit or a dead battery resumes
/// exactly where it left off. Drafts are local-only and never written to the repo or log;
/// "Save Progress" updates the draft, and only Submit/Finish writes a record.
struct WorkoutDraft: Codable, Sendable {
    /// Identifies which rendered session this draft belongs to, so it can be matched against
    /// the current `nextWorkout` on launch and discarded as orphaned if the plan has changed.
    var renderedSessionHash: String
    var sessionId: String
    var displayName: String
    var startedAt: String
    var savedAt: String
    var items: [DraftItem]

    // Cursor — owned by WorkoutLiveController, persisted so the "current set" survives a relaunch.
    var focusedItemID: String?
    var cursorItemID: String?
    var cursorSetID: Int?
    var cursorSetIsWarmup: Bool?
    var cursorAtEnd: Bool
}

struct DraftItem: Codable, Sendable {
    var itemId: String
    var exercise: String
    var isExtra: Bool
    var performedExercise: String?
    var swapLabel: String?
    var swapPolicy: SwapPolicy?
    var todayLoad: String?
    var warmups: [DraftSet]
    var sets: [DraftSet]
}

struct DraftSet: Codable, Sendable {
    var id: Int
    var reps: Int
    var load: String?
    var rpe: Double?
    var logged: Bool
    var isExtra: Bool
    var bypassed: Bool
}

/// Persists the single active workout draft to one atomic JSON file in Application Support.
/// A file (not UserDefaults) so writes flush predictably and survive a force-quit cleanly.
@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private let fileURL: URL
    /// Mirrors whether a draft currently exists on disk, so views can react without re-reading.
    private(set) var hasDraft: Bool

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("Knurled", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("workout-draft.json", isDirectory: false)
        hasDraft = fileManager.fileExists(atPath: fileURL.path)
    }

    func load() -> WorkoutDraft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkoutDraft.self, from: data)
    }

    func save(_ draft: WorkoutDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            hasDraft = true
        } catch {
            // A failed checkpoint must not interrupt the workout; the in-memory model is the
            // source of truth and the next auto-save will retry.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        hasDraft = false
    }
}

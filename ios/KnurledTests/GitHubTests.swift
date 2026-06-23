import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct GitHubTests {
    // §28 — a training commit gathers the log plus the regenerated state/build files.
    @Test func changedFilesIncludeLogAndGeneratedOutputs() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        _ = try await engine.build(dir: dir, write: true)
        try LogReader().appendEvent(line: "{\"id\":\"x\",\"type\":\"session_skipped\",\"session_id\":\"a1\"}", dir: dir, timestamp: "2026-06-24T09:00:00Z")

        let files = Set(GitHubChangedFiles.present(in: dir))
        #expect(files.contains("state/current.json"))
        #expect(files.contains("build/next-workout.json"))
        #expect(files.contains("logs/2026/06.jsonl"))
    }

    @Test func commitMessagesFollowTemplates() {
        func event(_ type: String) -> TrainingEvent {
            TrainingEvent(
                id: "e", type: type, schemaVersion: nil, program: nil, sessionId: "a1",
                planHash: nil, templateHash: nil, renderedSessionHash: nil, engineVersion: nil,
                startedAt: nil, completedAt: nil, savedAt: nil, status: nil,
                results: [], resultsAdded: [], effects: [], continuesEventId: nil,
                correctsEventId: nil, reason: nil, policy: nil, lane: nil, change: nil,
                cursor: nil, changes: []
            )
        }
        let ts = "2026-06-24T09:00:00Z"
        #expect(AppModel.commitMessage(for: event("session_completed"), timestamp: ts) == "Complete A1 - 2026-06-24")
        #expect(AppModel.commitMessage(for: event("session_skipped"), timestamp: ts) == "Skip A1 - push forward - 2026-06-24")
        #expect(AppModel.commitMessage(for: event("session_corrected"), timestamp: ts) == "Correct A1 - 2026-06-24")
    }

    @Test func githubCommonHeadersIncludeUserAgent() throws {
        let url = try #require(URL(string: "https://api.github.com/user"))
        var request = URLRequest(url: url)

        GitHub.applyCommonHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "User-Agent") == GitHub.userAgent)
    }
}

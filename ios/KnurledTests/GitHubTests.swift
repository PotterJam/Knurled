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
        try LogReader().upsert(day: Self.recordDay(), dir: dir)

        let files = Set(GitHubChangedFiles.present(in: dir))
        #expect(files.contains("state/current.json"))
        #expect(files.contains("build/current.ir.json"))
        #expect(files.contains("build/next-workout.json"))
        #expect(files.contains("logs/2026/06.json"))
        #expect(!files.contains("build/ir.json"))
    }

    @Test func syncRetriesPendingPushBeforePulling() async throws {
        let fake = FakeGitHubClient()
        let github = GitHubStore(makeClient: { _ in fake })
        github.authenticateForTesting(token: "token")
        let app = AppModel(github: github)
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await app.engine.build(dir: dir, write: true)
        try LogReader().upsert(day: Self.recordDay(), dir: dir)

        let repo = ActiveRepo(displayName: "owner/repo", url: dir, isSample: false)
        repo.remote = GitHubRemote(owner: "owner", name: "repo", branch: "main", headCommit: "base")
        repo.pendingPush = true
        app.activeRepo = repo
        app.phase = .ready

        await app.sync()

        let calls = await fake.calls
        #expect(calls.commitMessages == ["Sync pending Knurled changes"])
        #expect(calls.commitFiles.first?.contains("build/current.ir.json") == true)
        #expect(calls.pullCount == 1)
        #expect(repo.pendingPush == false)
        #expect(repo.remote?.headCommit == "pulled-head")
    }

    // `all` feeds the initial commit; its paths must be repo-relative and readable back via
    // `dir.appending(path:)` even when the working dir is a /var symlink (regression: paths
    // were coming back absolute on device, so the first commit read nothing).
    @Test func allReturnsReadableRelativePaths() throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }

        let all = GitHubChangedFiles.all(in: dir)
        #expect(!all.isEmpty)
        for path in all {
            #expect(!path.hasPrefix("/"))
            #expect(FileManager.default.fileExists(
                atPath: dir.appending(path: path).path(percentEncoded: false)
            ))
        }
    }

    @Test func relativePathNormalizesPrivateVarAlias() throws {
        let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/app/Library/Application Support/Knurled/repos/PotterJam-gym")
        let file = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/app/Library/Application Support/Knurled/repos/PotterJam-gym/README.md")

        #expect(GitHubChangedFiles.repoRelativePath(for: file, root: root) == "README.md")
    }

    @Test func commitMessagesFollowTemplates() {
        let session = RenderedSession.minimalForTesting(sessionId: "a1")
        #expect(AppModel.commitMessage(session: session, mode: .advance, date: "2026-06-24") == "Complete A1 - 2026-06-24")
        #expect(AppModel.commitMessage(session: session, mode: .offDay, date: "2026-06-24") == "Record off-day A1 - 2026-06-24")
        #expect(AppModel.commitMessage(session: session, mode: .reset, date: "2026-06-24") == "Reset A1 - 2026-06-24")
    }

    @Test func githubCommonHeadersIncludeUserAgent() throws {
        let url = try #require(URL(string: "https://api.github.com/user"))
        var request = URLRequest(url: url)

        GitHub.applyCommonHeaders(to: &request)

        #expect(request.value(forHTTPHeaderField: "User-Agent") == GitHub.userAgent)
    }

    @Test func initialNumberSpecUsesVersionedTemplateReferences() {
        let fiveThreeOne = StarterTemplate(
            reference: "531.beginners@1.0.0",
            title: "5/3/1 for Beginners",
            subtitle: ""
        )
        let startingStrength = StarterTemplate(
            reference: "starting-strength.phase3@1.0.0",
            title: "Starting Strength Phase 3",
            subtitle: ""
        )

        #expect(InitialTrainingNumbers.spec(for: fiveThreeOne).block == .trainingMaxes)
        #expect(InitialTrainingNumbers.spec(for: startingStrength).fields.map(\.exercise).contains("power_clean"))
    }

    @Test func initialNumbersRewriteTemplatePlanBeforeFirstCommit() throws {
        let template = StarterTemplate(reference: "gzcl.gzclp@1.0.0", title: "GZCLP", subtitle: "")
        let spec = InitialTrainingNumbers.spec(for: template)
        let numbers = InitialTrainingNumbers(
            spec: spec,
            units: .lb,
            values: [
                "squat": "200",
                "bench": "135",
                "press": "85",
                "deadlift": "245",
            ]
        )
        let plan = """
        plan "My GZCLP" {
          template "gzcl.gzclp" version="1.0.0"
          units kg

          starts {
            squat "80kg"
            bench "55kg"
            press "37.5kg"
            deadlift "100kg"
          }

          accessories {
            A1.T3 lat_pulldown
          }
        }
        """

        let withUnits = AppModel.replacingPlanUnits(in: plan, with: .lb)
        let updated = try AppModel.replacingInitialNumberBlock(in: withUnits, with: numbers)

        #expect(updated.contains("\n  units lb\n"))
        #expect(updated.contains("""
          starts {
            squat "200lb"
            bench "135lb"
            press "85lb"
            deadlift "245lb"
          }
        """))
        #expect(updated.contains("  accessories {"))
        #expect(!updated.contains("80kg"))
    }
}

private extension GitHubTests {
    static func recordDay() -> DayRecord {
        DayRecord(
            date: "2026-06-24",
            program: nil,
            note: nil,
            lifts: [
                LiftRecord(
                    exercise: "squat",
                    weight: "80kg",
                    sets: [5, 5, 5],
                    metrics: [:],
                    note: nil
                ),
            ]
        )
    }
}

private extension RenderedSession {
    static func minimalForTesting(sessionId: String) -> RenderedSession {
        RenderedSession(
            type: "rendered_session",
            schemaVersion: "0.1",
            engineVersion: "0.1.0",
            sessionId: sessionId,
            displayName: sessionId.uppercased(),
            suggestedDate: nil,
            planHash: "sha256:plan",
            templateHash: "sha256:template",
            renderedSessionHash: "sha256:rendered",
            items: []
        )
    }
}

private actor FakeGitHubClient: GitHubClientProtocol {
    struct Calls {
        var commitMessages: [String] = []
        var commitFiles: [[String]] = []
        var pullCount = 0
    }

    private(set) var calls = Calls()

    func currentUser() async throws -> GitHubUser {
        GitHubUser(login: "test")
    }

    func repositories() async throws -> [GitHubRepo] {
        []
    }

    func createRepository(name: String, isPrivate: Bool) async throws -> GitHubRepo {
        GitHubRepo(id: 1, name: name, fullName: "test/\(name)", defaultBranch: "main", private: isPrivate, size: 1)
    }

    func pull(owner: String, repo: String, branch: String, into dir: URL) async throws -> String {
        calls.pullCount += 1
        return "pulled-head"
    }

    func commit(
        owner: String,
        repo: String,
        branch: String,
        baseCommit: String,
        files: [String],
        dir: URL,
        message: String
    ) async throws -> String {
        calls.commitMessages.append(message)
        calls.commitFiles.append(files)
        return "pushed-head"
    }

    func commitInitial(
        owner: String,
        repo: String,
        branch: String,
        files: [String],
        dir: URL,
        message: String
    ) async throws -> String {
        "initial-head"
    }
}

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
        try await Self.submitRecord(engine: engine, dir: dir)

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
        try await Self.submitRecord(engine: app.engine, dir: dir)

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

    @Test func engineMergesDistinctSameMonthRecordsByIdentity() async throws {
        let source = try SampleRepo.makeWorkingCopy()
        let target = try SampleRepo.makeWorkingCopy()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let engine = RustWorkoutEngine()
        try await Self.submitRecord(
            engine: engine,
            dir: source,
            startedAt: "2026-06-24T10:00:00Z"
        )
        try await Self.submitRecord(
            engine: engine,
            dir: target,
            startedAt: "2026-06-24T14:00:00Z",
            completedAt: "2026-06-24T15:00:00Z"
        )

        _ = try await engine.mergeRecordRepos(source: source, target: target)

        let records = try await engine.records(dir: target)
        #expect(records.count == 2)
        #expect(Set(records.map(\.id)).count == 2)
    }

    @Test func zeroSizeRepositoryStillConnectsWhenPullSucceeds() async throws {
        let fake = PullingGitHubClient()
        let github = GitHubStore(makeClient: { _ in fake })
        github.authenticateForTesting(token: "token")
        let app = AppModel(github: github)
        let githubRepo = GitHubRepo(
            id: 1,
            name: "gym",
            fullName: "owner/gym",
            defaultBranch: "main",
            private: true,
            size: 0
        )

        try await app.connect(repo: githubRepo)

        #expect(await fake.pullCount == 1)
        #expect(app.activeRepo?.displayName == "owner/gym")
        #expect(app.activeRepo?.remote?.headCommit == "pulled-head")
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

    // Regression: device-flow polling idles ~5s between requests, so the poll that finally
    // succeeds — right after GitHub accepts — routinely lands on a stale pooled connection and
    // fails with NSURLErrorNetworkConnectionLost (-1005). dataWithRetry must recover instead of
    // aborting sign-in with "The network connection was lost."
    @Test func dataWithRetryRecoversFromConnectionLost() async throws {
        ConnectionLostURLProtocol.reset(failuresBeforeSuccess: 1)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionLostURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "https://github.com/login/oauth/access_token"))
        let (_, response) = try await GitHub.dataWithRetry(for: URLRequest(url: url), session: session)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(ConnectionLostURLProtocol.attempts == 2)
    }

    @Test func dataWithRetryGivesUpAfterMaxRetries() async throws {
        ConnectionLostURLProtocol.reset(failuresBeforeSuccess: .max)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionLostURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "https://github.com/login/oauth/access_token"))
        await #expect(throws: URLError.self) {
            _ = try await GitHub.dataWithRetry(for: URLRequest(url: url), session: session, maxRetries: 2)
        }
        #expect(ConnectionLostURLProtocol.attempts == 3)
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

    @Test func initialNumbersResetGeneratedStateBeforeFirstCommit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RustWorkoutEngine()
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

        try await engine.initRepo(dir: dir, template: template.reference)
        try AppModel.apply(initialNumbers: numbers, to: dir)
        let outputs = try await engine.build(dir: dir, write: true)
        let squat = outputs.nextWorkout?.items.first { $0.progressionLane == "squat.t1" }

        #expect(outputs.state.lanes["squat.t1"]?.load == "200lb")
        #expect(squat?.prescription.sets.first?.load == "200lb")
    }
}

private extension GitHubTests {
    static func submitRecord(
        engine: any WorkoutEngine,
        dir: URL,
        startedAt: String = "2026-06-24T10:00:00Z",
        completedAt: String = "2026-06-24T11:00:00Z"
    ) async throws {
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        let input = ExecutionInput(
            renderedSessionHash: session.renderedSessionHash,
            startedAt: startedAt,
            completedAt: completedAt,
            inputs: session.items.map { item in
                if item.executionContract.recommendedInput == InputMode.amrapFinalSet {
                    return ItemInput(
                        itemId: item.itemId,
                        mode: InputMode.amrapFinalSet,
                        finalSetReps: item.prescription.sets.last?.targetReps ?? 1
                    )
                }
                return ItemInput(
                    itemId: item.itemId,
                    mode: InputMode.perSetReps,
                    sets: item.prescription.sets.map {
                        ActualSet(set: $0.set, load: $0.load, reps: $0.targetReps)
                    }
                )
            }
        )
        _ = try await engine.submit(
            dir: dir,
            session: session,
            input: input,
            mode: .advance,
            date: "2026-06-24"
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

/// Stub transport that fails the first `failuresBeforeSuccess` requests with the same
/// `NSURLErrorNetworkConnectionLost` URLSession raises against a stale pooled connection,
/// then answers 200. Lets us exercise `GitHub.dataWithRetry` deterministically.
private final class ConnectionLostURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remainingFailures = 0
    nonisolated(unsafe) private static var attemptCount = 0

    static func reset(failuresBeforeSuccess: Int) {
        lock.lock()
        defer { lock.unlock() }
        remainingFailures = failuresBeforeSuccess
        attemptCount = 0
    }

    static var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attemptCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.attemptCount += 1
        let shouldFail = Self.remainingFailures > 0
        if shouldFail { Self.remainingFailures -= 1 }
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
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

private actor PullingGitHubClient: GitHubClientProtocol {
    private(set) var pullCount = 0

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
        pullCount += 1
        let source = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: source) }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.copyItem(at: source, to: dir)
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
        "pushed-head"
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

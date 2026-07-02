import Testing
import Foundation
@testable import Knurled

@MainActor
@Suite struct OnboardingTests {
    // Onboarding creates the training repo locally — no GitHub involved — with the chosen
    // starting numbers applied before the first build.
    @Test func createTrainingRepositoryBuildsLocalRepoFromTemplate() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(repos: RepoManager(rootOverride: root))

        let template = StarterTemplate(reference: "gzcl.gzclp@1.0.0", title: "GZCLP", subtitle: "")
        let repo = try await app.createTrainingRepository(
            template: template,
            initialNumbers: gzclpNumbers(for: template)
        )

        #expect(app.phase == .ready)
        #expect(app.activeRepo === repo)
        #expect(repo.remote == nil)
        #expect(repo.displayName == "GZCLP")
        #expect(repo.nextWorkout != nil)
        #expect(repo.state?.lanes["squat.t1"]?.load == "200lb")
        #expect(repo.url.path(percentEncoded: false).hasPrefix(root.path(percentEncoded: false)))
    }

    // A second onboarding run (e.g. after restore-then-start-fresh) must never clobber an
    // existing working copy: slugs unique-ify instead.
    @Test func newWorkingDirectoriesNeverReuseAnExistingSlug() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repos = RepoManager(rootOverride: root)

        let first = try await repos.newWorkingDirectory(preferredSlug: "my-training")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = try await repos.newWorkingDirectory(preferredSlug: "my-training")

        #expect(first.lastPathComponent == "my-training")
        #expect(second.lastPathComponent == "my-training-2")
    }

    // Without iCloud (or with the test override), storage is on-device.
    @Test func storageFallsBackToLocalWithoutICloud() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repos = RepoManager(rootOverride: root)

        #expect(await repos.storageLocation() == .local)
    }

    // Backing up pushes the entire working copy as the initial commit and records the
    // remote, so every later training commit lands on GitHub too.
    @Test func createBackupRepositoryPushesWorkingCopyAndLinksRemote() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = BackupRecordingClient()
        let github = GitHubStore(makeClient: { _ in fake })
        github.authenticateForTesting(token: "token")
        let app = AppModel(repos: RepoManager(rootOverride: root), github: github)

        let template = StarterTemplate(reference: "gzcl.gzclp@1.0.0", title: "GZCLP", subtitle: "")
        let repo = try await app.createTrainingRepository(
            template: template,
            initialNumbers: gzclpNumbers(for: template)
        )

        try await app.createBackupRepository(name: "my-training", isPrivate: true)

        let created = await fake.createdRepos
        let initialCommits = await fake.initialCommits
        #expect(created == [Created(name: "my-training", isPrivate: true)])
        #expect(initialCommits.count == 1)
        #expect(initialCommits.first?.files.contains("build/current.ir.json") == true)
        #expect(initialCommits.first?.files.contains(where: { $0.hasSuffix("plan.fitspec") }) == true)
        #expect(repo.remote == GitHubRemote(owner: "test", name: "my-training", branch: "main", headCommit: "initial-head"))
        #expect(repo.pendingPush == false)
    }

    // Unlinking the backup keeps the working copy untouched and just drops the remote.
    @Test func unlinkBackupDropsRemoteOnly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(repos: RepoManager(rootOverride: root))

        let template = StarterTemplate(reference: "gzcl.gzclp@1.0.0", title: "GZCLP", subtitle: "")
        let repo = try await app.createTrainingRepository(
            template: template,
            initialNumbers: gzclpNumbers(for: template)
        )
        repo.remote = GitHubRemote(owner: "test", name: "gym", branch: "main", headCommit: "head")
        repo.pendingPush = true

        app.unlinkBackup()

        #expect(repo.remote == nil)
        #expect(repo.pendingPush == false)
        #expect(repo.nextWorkout != nil)
    }

    // Old builds persisted the bundled sample repo; restoring it would resurrect the mock
    // plan onboarding replaced. Legacy sample selections decode but are skipped.
    @Test func restoreSelectionSkipsLegacySampleSelections() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "knurled.activeRepoSelection"
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Materialize the sample working copy so only the isSample flag stands between the
        // persisted selection and a successful restore.
        let sampleDir = root.appending(path: "repos/sample-gzclp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)

        let legacy = #"{"slug":"sample-gzclp","displayName":"Sample · GZCLP","isSample":true,"pendingPush":false}"#
        UserDefaults.standard.set(Data(legacy.utf8), forKey: key)
        let app = AppModel(repos: RepoManager(rootOverride: root))

        #expect(await app.restoreSelection() == false)
        #expect(app.activeRepo == nil)
    }
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "knurled-onboarding-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func gzclpNumbers(for template: StarterTemplate) -> InitialTrainingNumbers {
    InitialTrainingNumbers(
        spec: InitialTrainingNumbers.spec(for: template),
        units: .lb,
        values: [
            "squat": "200",
            "bench": "135",
            "press": "85",
            "deadlift": "245",
        ]
    )
}

private struct Created: Equatable {
    let name: String
    let isPrivate: Bool
}

private actor BackupRecordingClient: GitHubClientProtocol {
    struct InitialCommit {
        let owner: String
        let repo: String
        let branch: String
        let files: [String]
        let message: String
    }

    private(set) var createdRepos: [Created] = []
    private(set) var initialCommits: [InitialCommit] = []

    func currentUser() async throws -> GitHubUser {
        GitHubUser(login: "test")
    }

    func repositories() async throws -> [GitHubRepo] {
        []
    }

    func createRepository(name: String, isPrivate: Bool) async throws -> GitHubRepo {
        createdRepos.append(Created(name: name, isPrivate: isPrivate))
        return GitHubRepo(id: 1, name: name, fullName: "test/\(name)", defaultBranch: "main", private: isPrivate, size: 0)
    }

    func pull(owner: String, repo: String, branch: String, into dir: URL) async throws -> String {
        "pulled-head"
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
        initialCommits.append(InitialCommit(owner: owner, repo: repo, branch: branch, files: files, message: message))
        return "initial-head"
    }
}

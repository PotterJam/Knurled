import Foundation

struct GitHubRemote: Codable, Sendable, Hashable {
    let owner: String
    let name: String
    let branch: String
    var headCommit: String
}

enum StarterTemplate: String, CaseIterable, Identifiable {
    case gzclpStandard
    case gzclpPZero
    case fiveThreeOneBasic
    case fiveThreeOneBeginners
    case startingStrengthPhase1
    case startingStrengthPhase2
    case startingStrengthPhase3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gzclpStandard: "GZCLP Standard"
        case .gzclpPZero: "GZCLP P-Zero"
        case .fiveThreeOneBasic: "5/3/1 Basic"
        case .fiveThreeOneBeginners: "5/3/1 for Beginners"
        case .startingStrengthPhase1: "Starting Strength Phase 1"
        case .startingStrengthPhase2: "Starting Strength Phase 2"
        case .startingStrengthPhase3: "Starting Strength Phase 3"
        }
    }

    var subtitle: String {
        switch self {
        case .gzclpStandard: "Simple linear progression with A/B rotation."
        case .gzclpPZero: "GZCLP variant with the same starter lifts."
        case .fiveThreeOneBasic: "Four-day 5/3/1 starter using training maxes."
        case .fiveThreeOneBeginners: "Beginner-friendly 5/3/1 starter."
        case .startingStrengthPhase1: "Novice A/B progression with squat, press, bench, and deadlift."
        case .startingStrengthPhase2: "Adds the next novice phase while staying template-driven."
        case .startingStrengthPhase3: "Adds power cleans for later novice progression."
        }
    }

    var reference: String {
        switch self {
        case .gzclpStandard: "gzclp.standard@1.0.0"
        case .gzclpPZero: "gzclp.pzero@1.0.0"
        case .fiveThreeOneBasic: "531.basic@1.0.0"
        case .fiveThreeOneBeginners: "531.beginners@1.0.0"
        case .startingStrengthPhase1: "starting-strength.phase1@1.0.0"
        case .startingStrengthPhase2: "starting-strength.phase2@1.0.0"
        case .startingStrengthPhase3: "starting-strength.phase3@1.0.0"
        }
    }
}

/// The canonical + generated files a training commit may touch (spec §28).
enum GitHubChangedFiles {
    static func present(in dir: URL) -> [String] {
        var paths: [String] = []
        // Logs follow the engine convention logs/<yyyy>/<mm>.jsonl; build the repo-relative
        // path from the trailing components to stay robust to /var -> /private symlinks.
        let logs = dir.appending(path: "logs", directoryHint: .isDirectory)
        if let enumerator = FileManager.default.enumerator(at: logs, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                paths.append("logs/" + url.pathComponents.suffix(2).joined(separator: "/"))
            }
        }
        for generated in ["state/current.json", "build/state.json", "build/ir.json",
                          "build/next-workout.json", "build/validation.json"] {
            if FileManager.default.fileExists(atPath: dir.appending(path: generated).path(percentEncoded: false)) {
                paths.append(generated)
            }
        }
        return paths
    }

    static func all(in dir: URL) -> [String] {
        // Resolve symlinks up front so the enumerator's URLs (iOS hands them back under
        // /private/var while the working dir is /var/…) are rooted at the same place, then
        // derive each repo-relative path by dropping the base's path components. String-prefix
        // stripping was fragile here (symlinks + the directory URL's trailing slash) and left
        // paths absolute, so the initial commit couldn't read any file back.
        let base = dir.resolvingSymlinksInPath()
        let baseComponentCount = base.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let relative = url.pathComponents.dropFirst(baseComponentCount).joined(separator: "/")
            guard !relative.isEmpty, !relative.split(separator: "/").contains(".DS_Store") else { continue }
            paths.append(relative)
        }
        return paths.sorted()
    }
}

extension AppModel {
    /// Pulls a GitHub repo into a working copy and makes it the active repo.
    ///
    /// Empty repositories (no commits yet) can't be pulled — GitHub's Git Data API answers
    /// with 409. We surface `GitHubError.emptyRepository` so the caller can offer to seed it
    /// with a starter template via `initializeRepository(githubRepo:template:)`.
    func connect(repo githubRepo: GitHubRepo) async throws {
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        let slug = "\(githubRepo.owner)-\(githubRepo.name)"
        let dir = try repos.workingDirectory(for: slug)
        let head: String
        do {
            head = try await client.pull(
                owner: githubRepo.owner,
                repo: githubRepo.name,
                branch: githubRepo.defaultBranch,
                into: dir
            )
        } catch where GitHubError.isEmptyRepository(error) {
            throw GitHubError.emptyRepository
        }
        let active = ActiveRepo(displayName: githubRepo.fullName, url: dir, isSample: false)
        active.remote = GitHubRemote(
            owner: githubRepo.owner,
            name: githubRepo.name,
            branch: githubRepo.defaultBranch,
            headCommit: head
        )
        _ = try await engine.build(dir: dir, write: false)
        await active.refresh(engine: engine)
        activeRepo = active
        phase = .ready
        persistSelection()
    }

    func createStarterRepository(
        name rawName: String,
        template: StarterTemplate,
        isPrivate: Bool = true
    ) async throws {
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRepositoryName(name) else { throw GitHubError.invalidRepositoryName }

        let githubRepo = try await client.createRepository(name: name, isPrivate: isPrivate)
        try await initializeRepository(githubRepo: githubRepo, template: template)
    }

    /// Seeds an existing empty GitHub repository with a starter template: builds the template
    /// locally, makes the repo's first commit, and makes it the active repo. Shared by the
    /// create-new flow and the "begin an empty repo" flow.
    func initializeRepository(githubRepo: GitHubRepo, template: StarterTemplate) async throws {
        guard let client = github.client() else { throw GitHubError.badResponse("Not signed in to GitHub.") }
        let slug = "\(githubRepo.owner)-\(githubRepo.name)"
        let dir = try repos.workingDirectory(for: slug)
        if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: dir)
        }
        try await engine.initRepo(dir: dir, template: template.reference)
        _ = try await engine.build(dir: dir, write: true)
        let branch = githubRepo.defaultBranch.isEmpty ? "main" : githubRepo.defaultBranch
        let head = try await client.commitInitial(
            owner: githubRepo.owner,
            repo: githubRepo.name,
            branch: branch,
            files: GitHubChangedFiles.all(in: dir),
            dir: dir,
            message: "Initialize Knurled training repo"
        )

        let active = ActiveRepo(displayName: githubRepo.fullName, url: dir, isSample: false)
        active.remote = GitHubRemote(
            owner: githubRepo.owner,
            name: githubRepo.name,
            branch: branch,
            headCommit: head
        )
        await active.refresh(engine: engine)
        activeRepo = active
        phase = .ready
        persistSelection()
        await github.loadRepos()
    }

    private static func isValidRepositoryName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Pulls the latest remote state into the active GitHub repo and rebuilds (spec §27).
    func sync() async {
        guard let repo = activeRepo, let remote = repo.remote, let client = github.client() else {
            await refresh()
            return
        }
        if repo.pendingPush {
            repo.loadError = "You have local changes that haven't pushed yet. Push before pulling."
            return
        }
        do {
            let head = try await client.pull(
                owner: remote.owner,
                repo: remote.name,
                branch: remote.branch,
                into: repo.url
            )
            repo.remote?.headCommit = head
            _ = try await engine.build(dir: repo.url, write: true)
            await repo.refresh(engine: engine)
        } catch {
            repo.loadError = error.localizedDescription
        }
    }

    /// Pushes the working copy's changed files as one commit. Best-effort: a failure
    /// (e.g. offline) marks the repo pending rather than losing the local commit (spec §30).
    func pushIfConnected(repo: ActiveRepo, message: String) async {
        guard let remote = repo.remote, let client = github.client() else { return }
        do {
            let head = try await client.commit(
                owner: remote.owner,
                repo: remote.name,
                branch: remote.branch,
                baseCommit: remote.headCommit,
                files: GitHubChangedFiles.present(in: repo.url),
                dir: repo.url,
                message: message
            )
            repo.remote?.headCommit = head
            repo.pendingPush = false
        } catch {
            repo.pendingPush = true
            repo.loadError = "Saved locally. Couldn't push to GitHub yet: \(error.localizedDescription)"
        }
    }
}

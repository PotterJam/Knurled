import Foundation
import Observation

@MainActor
@Observable
final class GitHubStore {
    enum Phase {
        case signedOut
        case awaitingAuthorization(DeviceCodeResponse)
        case signedIn(login: String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var repos: [GitHubRepo] = []
    private(set) var installations: [GitHubInstallation] = []
    private(set) var isLoadingRepos = false
    var errorMessage: String?

    private let tokenStore = TokenStore()
    private let makeClient: @Sendable (@escaping GitHubTokenProvider) -> any GitHubClientProtocol
    private var credentials: GitHubCredentials?
    private var refreshTask: Task<GitHubCredentials, Error>?
    private var signInTask: Task<Void, Never>?

    init(
        makeClient: @escaping @Sendable (@escaping GitHubTokenProvider) -> any GitHubClientProtocol = {
            GitHubClient(token: $0)
        }
    ) {
        self.makeClient = makeClient
    }

    var isConfigured: Bool { GitHubConfig.isConfigured }

    var login: String? {
        if case .signedIn(let login) = phase { return login }
        return nil
    }

    /// True once the user has installed the GitHub App somewhere, even with zero
    /// repositories selected. Distinguishes "install the app" from "select some repos".
    var hasInstallations: Bool { !installations.isEmpty }

    /// Restores a previously saved session from the Keychain on launch, refreshing the
    /// access token if it lapsed since the last run.
    func restore() async {
        guard let saved = tokenStore.load() else { return }
        credentials = saved
        do {
            guard let client = client() else { return }
            let user = try await client.currentUser()
            phase = .signedIn(login: user.login)
        } catch {
            tokenStore.clear()
            credentials = nil
        }
    }

    func signIn() {
        guard let clientID = GitHubConfig.clientID else {
            errorMessage = GitHubError.noClientID.errorDescription
            return
        }
        tokenStore.clear()
        credentials = nil
        repos = []
        installations = []
        errorMessage = nil
        signInTask?.cancel()
        signInTask = Task { await runDeviceFlow(clientID: clientID) }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        if case .awaitingAuthorization = phase { phase = .signedOut }
    }

    func signOut() {
        signInTask?.cancel()
        signInTask = nil
        tokenStore.clear()
        credentials = nil
        repos = []
        installations = []
        phase = .signedOut
    }

    /// Loads every repository the user has granted the GitHub App, across all of their
    /// installations (personal account plus any orgs).
    func loadRepos() async {
        guard let client = client() else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            let installations = try await client.installations()
            var repos: [GitHubRepo] = []
            for installation in installations {
                repos += try await client.repositories(installationID: installation.id)
            }
            self.installations = installations
            self.repos = repos.sorted {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func client() -> (any GitHubClientProtocol)? {
        guard credentials != nil else { return nil }
        return makeClient { [weak self] in
            guard let self else { throw GitHubError.notSignedIn }
            return try await self.validAccessToken()
        }
    }

    /// Returns an access token that's valid right now, refreshing the pair first when the
    /// current one is at or near expiry. Concurrent callers share one in-flight refresh —
    /// GitHub invalidates a refresh token the moment it's used, so a second racing refresh
    /// would kill the session.
    func validAccessToken() async throws -> String {
        guard let credentials else { throw GitHubError.notSignedIn }
        guard credentials.needsRefresh(), let refreshToken = credentials.refreshToken else {
            return credentials.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        guard let clientID = GitHubConfig.clientID else { throw GitHubError.noClientID }
        let task = Task {
            try await GitHubAppAuth(clientID: clientID).refresh(refreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            self.credentials = refreshed
            tokenStore.save(refreshed)
            return refreshed.accessToken
        } catch GitHubError.sessionExpired {
            // The refresh token itself was rejected; nothing recovers this silently.
            signOut()
            throw GitHubError.sessionExpired
        }
    }

    func authenticateForTesting(token: String, login: String = "test") {
        credentials = GitHubCredentials(accessToken: token)
        phase = .signedIn(login: login)
    }

    private func runDeviceFlow(clientID: String) async {
        let auth = GitHubAppAuth(clientID: clientID)
        do {
            let code = try await auth.requestCode()
            phase = .awaitingAuthorization(code)
            let credentials = try await auth.pollForToken(
                deviceCode: code.deviceCode,
                interval: code.interval
            )
            self.credentials = credentials
            tokenStore.save(credentials)
            guard let client = client() else { return }
            let user = try await client.currentUser()
            phase = .signedIn(login: user.login)
            await loadRepos()
        } catch is CancellationError {
            // User cancelled; phase already reset by cancelSignIn().
        } catch {
            tokenStore.clear()
            credentials = nil
            repos = []
            installations = []
            errorMessage = error.localizedDescription
            phase = .signedOut
        }
    }
}

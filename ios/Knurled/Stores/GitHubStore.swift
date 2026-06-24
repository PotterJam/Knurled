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
    private(set) var isLoadingRepos = false
    var errorMessage: String?

    private let tokenStore = TokenStore()
    private let makeClient: @Sendable (String) -> any GitHubClientProtocol
    private var token: String?
    private var signInTask: Task<Void, Never>?

    init(makeClient: @escaping @Sendable (String) -> any GitHubClientProtocol = { GitHubClient(token: $0) }) {
        self.makeClient = makeClient
    }

    var isConfigured: Bool { GitHubConfig.isConfigured }

    var login: String? {
        if case .signedIn(let login) = phase { return login }
        return nil
    }

    /// Restores a previously saved session from the Keychain on launch.
    func restore() async {
        guard let saved = tokenStore.load() else { return }
        token = saved
        do {
            let user = try await makeClient(saved).currentUser()
            phase = .signedIn(login: user.login)
        } catch {
            tokenStore.clear()
            token = nil
        }
    }

    func signIn() {
        guard let clientID = GitHubConfig.clientID else {
            errorMessage = GitHubError.noClientID.errorDescription
            return
        }
        tokenStore.clear()
        token = nil
        repos = []
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
        token = nil
        repos = []
        phase = .signedOut
    }

    func loadRepos() async {
        guard let token else { return }
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        do {
            repos = try await makeClient(token).repositories()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func client() -> (any GitHubClientProtocol)? {
        token.map(makeClient)
    }

    func authenticateForTesting(token: String, login: String = "test") {
        self.token = token
        phase = .signedIn(login: login)
    }

    private func runDeviceFlow(clientID: String) async {
        let flow = GitHubDeviceFlow(clientID: clientID)
        do {
            let code = try await flow.requestCode()
            phase = .awaitingAuthorization(code)
            let accessToken = try await flow.pollForToken(
                deviceCode: code.deviceCode,
                interval: code.interval
            )
            let user = try await makeClient(accessToken).currentUser()
            tokenStore.save(accessToken)
            token = accessToken
            phase = .signedIn(login: user.login)
            await loadRepos()
        } catch is CancellationError {
            // User cancelled; phase already reset by cancelSignIn().
        } catch {
            tokenStore.clear()
            token = nil
            repos = []
            errorMessage = error.localizedDescription
            phase = .signedOut
        }
    }
}

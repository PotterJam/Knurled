import Foundation

enum GitHub {
    static let userAgent = "Knurled-iOS"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func applyCommonHeaders(to request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// Performs a URLSession data request, retrying the transient connection failures that
    /// otherwise abort sign-in with "The network connection was lost."
    ///
    /// iOS surfaces `NSURLErrorNetworkConnectionLost` (-1005) when URLSession hands a request
    /// to a pooled keep-alive connection the server has already closed. Device-flow polling
    /// idles ~5s between requests, so the poll that finally succeeds — right after the user
    /// authorizes on github.com — routinely lands on a stale connection and fails. A retry
    /// opens a fresh connection instead of bubbling the error up as a fatal sign-in failure.
    static func dataWithRetry(
        for request: URLRequest,
        session: URLSession = .shared,
        maxRetries: Int = 2
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await session.data(for: request)
            } catch let error as URLError where isRetriable(error) && attempt < maxRetries {
                attempt += 1
                // A brief pause lets the dead connection drain from the pool before we retry.
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Transient transport errors worth retrying. Deliberately narrow: real failures like
    /// `.notConnectedToInternet` or `.cancelled` should surface immediately, not loop.
    private static func isRetriable(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .cannotConnectToHost, .timedOut:
            return true
        default:
            return false
        }
    }
}

enum GitHubError: Error, Sendable, LocalizedError {
    case noClientID
    case notSignedIn
    case sessionExpired
    case http(Int, String)
    case expiredToken
    case accessDenied
    case badResponse(String)
    case invalidRepositoryName
    case emptyRepository
    case repositoryNotAccessible(String)

    var errorDescription: String? {
        switch self {
        case .noClientID:
            return "No GitHub App client ID is configured. Add GITHUB_APP_CLIENT_ID to Config/Secrets.xcconfig."
        case .notSignedIn:
            return "Not signed in to GitHub."
        case .sessionExpired:
            return "Your GitHub session expired. Please connect GitHub again."
        case .http(let code, let body):
            return "GitHub request failed (\(code)). \(body.prefix(200))"
        case .expiredToken:
            return "The sign-in code expired. Please try again."
        case .accessDenied:
            return "Access was denied during sign-in."
        case .badResponse(let detail):
            return "Unexpected response from GitHub. \(detail)"
        case .invalidRepositoryName:
            return "Choose a repository name using letters, numbers, dashes, underscores, or dots."
        case .emptyRepository:
            return "This repository is empty. Pick a starter template to initialize it."
        case .repositoryNotAccessible(let fullName):
            return "Created \(fullName), but the app hasn't been granted access to it yet. Add it under Manage repository access, then connect it from the list."
        }
    }

    /// GitHub answers Git Data API reads with 409 "Git Repository is empty." when a repo
    /// has no commits yet. Detect that so we can offer to initialize the repo instead.
    static func isEmptyRepository(_ error: Error) -> Bool {
        if case GitHubError.http(409, let body) = error {
            return body.localizedCaseInsensitiveContains("empty")
        }
        return false
    }
}

struct DeviceCodeResponse: Codable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
}

struct AccessTokenResponse: Codable, Sendable {
    let accessToken: String?
    let expiresIn: Int?
    let refreshToken: String?
    let refreshTokenExpiresIn: Int?
    let error: String?
    let interval: Int?

    /// Converts the relative `expires_in` fields into absolute dates. GitHub omits them
    /// entirely when the app has token expiration disabled, leaving non-expiring
    /// credentials.
    func credentials(now: Date = .now) -> GitHubCredentials? {
        guard let accessToken else { return nil }
        return GitHubCredentials(
            accessToken: accessToken,
            accessTokenExpiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        )
    }
}

/// A GitHub App user access token (`ghu_…`) plus the refresh token (`ghr_…`) needed to
/// renew it. Access tokens live 8 hours, refresh tokens 6 months; both dates are nil when
/// the app has token expiration disabled.
struct GitHubCredentials: Codable, Sendable {
    let accessToken: String
    var accessTokenExpiresAt: Date? = nil
    var refreshToken: String? = nil
    var refreshTokenExpiresAt: Date? = nil

    /// True when the access token is expired or about to be. The 5-minute margin keeps
    /// requests already in flight from racing the expiry.
    func needsRefresh(now: Date = .now) -> Bool {
        guard let accessTokenExpiresAt else { return false }
        return now > accessTokenExpiresAt.addingTimeInterval(-300)
    }
}

struct GitHubUser: Codable, Sendable {
    let login: String
}

/// One installation of the GitHub App — a user or organization that installed it and
/// granted it some set of repositories.
struct GitHubInstallation: Codable, Sendable, Identifiable {
    struct Account: Codable, Sendable { let login: String }
    let id: Int
    let account: Account?
    /// "all" or "selected".
    let repositorySelection: String?
}

struct GitHubInstallationList: Codable, Sendable {
    let installations: [GitHubInstallation]
}

struct GitHubRepoList: Codable, Sendable {
    let repositories: [GitHubRepo]
}

struct GitHubRepo: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let defaultBranch: String
    let `private`: Bool
    /// Repository size in KB from GitHub's list endpoint. This is display metadata only:
    /// small repositories can report 0 KB even when they have commits, so emptiness must be
    /// determined by attempting to read the branch and handling GitHub's empty-repo 409.
    var size: Int?

    var owner: String { String(fullName.split(separator: "/").first ?? "") }
}

struct GitHubCreateRepoRequest: Encodable {
    var name: String
    var description: String
    var `private`: Bool
    var autoInit: Bool
}

struct GitHubRef: Codable, Sendable {
    struct Object: Codable, Sendable { let sha: String }
    let object: Object
}

struct GitHubCommitObject: Codable, Sendable {
    struct TreeRef: Codable, Sendable { let sha: String }
    let tree: TreeRef
}

struct GitHubTree: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let type: String
        let sha: String
    }
    let tree: [Entry]
}

struct GitHubBlob: Codable, Sendable {
    let content: String
    let encoding: String
}

struct ShaResponse: Codable, Sendable {
    let sha: String
}

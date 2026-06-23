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
}

enum GitHubError: Error, Sendable, LocalizedError {
    case noClientID
    case http(Int, String)
    case expiredToken
    case accessDenied
    case badResponse(String)
    case invalidRepositoryName
    case emptyRepository

    var errorDescription: String? {
        switch self {
        case .noClientID:
            return "No GitHub client ID is configured. Add GITHUB_CLIENT_ID to Config/Secrets.xcconfig."
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
    let error: String?
    let interval: Int?
}

struct GitHubUser: Codable, Sendable {
    let login: String
}

struct GitHubRepo: Codable, Sendable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String
    let defaultBranch: String
    let `private`: Bool
    /// Repository size in KB. GitHub reports 0 for a repo with no commits, which lets us
    /// offer to initialize it before attempting a pull that would 409.
    var size: Int?

    var owner: String { String(fullName.split(separator: "/").first ?? "") }

    var isEmpty: Bool { (size ?? 0) == 0 }
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

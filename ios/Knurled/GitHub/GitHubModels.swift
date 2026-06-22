import Foundation

enum GitHub {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

enum GitHubError: Error, Sendable, LocalizedError {
    case noClientID
    case http(Int, String)
    case expiredToken
    case accessDenied
    case badResponse

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
        case .badResponse:
            return "Unexpected response from GitHub."
        }
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

    var owner: String { String(fullName.split(separator: "/").first ?? "") }
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

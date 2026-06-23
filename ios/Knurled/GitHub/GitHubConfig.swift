import Foundation

enum GitHubConfig {
    /// The OAuth App client ID, injected via Config/Secrets.xcconfig -> Info.plist.
    /// Returns nil when unset or still the sample placeholder.
    static var clientID: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = trimmed,
              !value.isEmpty,
              value != "your_github_oauth_client_id"
        else { return nil }
        return value
    }

    static var isConfigured: Bool { clientID != nil }
}

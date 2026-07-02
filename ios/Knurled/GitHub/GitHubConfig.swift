import Foundation

enum GitHubConfig {
    /// The GitHub App client ID (starts with `Iv`), injected via
    /// Config/Secrets.xcconfig -> Info.plist. Returns nil when unset or still the
    /// sample placeholder.
    static var clientID: String? {
        value(forInfoKey: "GitHubAppClientID", placeholder: "your_github_app_client_id")
    }

    /// The GitHub App's URL slug (the `<name>` in github.com/apps/<name>), used to link
    /// users to the install/repository-selection page. Optional: without it we fall back
    /// to the generic installations settings page.
    static var appName: String? {
        value(forInfoKey: "GitHubAppName", placeholder: "your_github_app_name")
    }

    static var isConfigured: Bool { clientID != nil }

    /// Where users pick which repositories the app can access. GitHub shows the install
    /// page for new users and the existing installation's repository picker otherwise.
    static var installURL: URL {
        if let appName, let url = URL(string: "https://github.com/apps/\(appName)/installations/new") {
            return url
        }
        return URL(string: "https://github.com/settings/installations")!
    }

    private static func value(forInfoKey key: String, placeholder: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = trimmed, !value.isEmpty, value != placeholder else { return nil }
        return value
    }
}

import Foundation

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var gitHubClientID: String? {
        guard let value = infoDictionary?["GitHubClientID"] as? String,
              !value.isEmpty,
              value != "your_github_oauth_client_id"
        else { return nil }
        return value
    }
}

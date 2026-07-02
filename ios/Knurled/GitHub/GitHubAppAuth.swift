import Foundation

/// Authentication against a GitHub App: device-flow sign-in plus refresh of the expiring
/// user access tokens the app hands out. GitHub Apps don't use OAuth scopes — the token is
/// limited to the permissions of the app and the repositories the user granted it — and
/// neither the device flow nor (for device-flow tokens) the refresh grant needs a client
/// secret, so the whole flow runs on-device.
struct GitHubAppAuth: Sendable {
    let clientID: String

    func requestCode() async throws -> DeviceCodeResponse {
        let data = try await post(
            "https://github.com/login/device/code",
            form: ["client_id": clientID]
        )
        return try GitHub.decoder().decode(DeviceCodeResponse.self, from: data)
    }

    func pollForToken(deviceCode: String, interval: Int) async throws -> GitHubCredentials {
        var delaySeconds = UInt64(max(interval, 5))
        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            let data = try await post(
                "https://github.com/login/oauth/access_token",
                form: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            let response = try GitHub.decoder().decode(AccessTokenResponse.self, from: data)
            if let credentials = response.credentials() { return credentials }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                delaySeconds += 5
            case "expired_token":
                throw GitHubError.expiredToken
            case "access_denied":
                throw GitHubError.accessDenied
            default:
                throw GitHubError.http(0, response.error ?? "unknown device-flow error")
            }
        }
        throw CancellationError()
    }

    /// Exchanges a refresh token for a new user access token + refresh token pair. The old
    /// pair stops working the moment this succeeds, so the caller must persist the result.
    func refresh(refreshToken: String) async throws -> GitHubCredentials {
        let data = try await post(
            "https://github.com/login/oauth/access_token",
            form: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        let response = try GitHub.decoder().decode(AccessTokenResponse.self, from: data)
        if let credentials = response.credentials() { return credentials }
        // bad_refresh_token means expired or already used — either way the session is over.
        if response.error == "bad_refresh_token" { throw GitHubError.sessionExpired }
        throw GitHubError.http(0, response.error ?? "unknown token-refresh error")
    }

    private func post(_ urlString: String, form: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw GitHubError.badResponse("Invalid auth URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        GitHub.applyCommonHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await GitHub.dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse("Non-HTTP auth response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

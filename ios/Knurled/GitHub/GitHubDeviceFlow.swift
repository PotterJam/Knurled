import Foundation

struct GitHubDeviceFlow: Sendable {
    let clientID: String
    var scope = "repo"

    func requestCode() async throws -> DeviceCodeResponse {
        let data = try await post(
            "https://github.com/login/device/code",
            form: ["client_id": clientID, "scope": scope]
        )
        return try GitHub.decoder().decode(DeviceCodeResponse.self, from: data)
    }

    func pollForToken(deviceCode: String, interval: Int) async throws -> String {
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
            if let token = response.accessToken { return token }
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

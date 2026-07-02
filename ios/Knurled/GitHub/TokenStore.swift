import Foundation
import Security

/// Keychain persistence for the GitHub App credentials (access + refresh token pair),
/// stored as one JSON blob.
struct TokenStore: Sendable {
    private let service = "com.knurled.app.github"
    private let account = "app-credentials"
    /// The OAuth-App-era entry that held a bare access token. Those tokens belong to the
    /// retired OAuth app, so they're deleted on sight; users sign in again once.
    private let legacyAccount = "access-token"

    func save(_ credentials: GitHubCredentials) {
        guard let data = try? Self.encoder().encode(credentials) else { return }
        SecItemDelete(query(for: account) as CFDictionary)
        var query = query(for: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func load() -> GitHubCredentials? {
        SecItemDelete(query(for: legacyAccount) as CFDictionary)
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? Self.decoder().decode(GitHubCredentials.self, from: data)
        else { return nil }
        return credentials
    }

    func clear() {
        SecItemDelete(query(for: account) as CFDictionary)
        SecItemDelete(query(for: legacyAccount) as CFDictionary)
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

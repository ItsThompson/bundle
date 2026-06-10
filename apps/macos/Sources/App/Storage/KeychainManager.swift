import Foundation
import Security

/// Protocol for token storage operations, enabling test substitution.
protocol TokenStore {
    func saveTokens(access: String, refresh: String) throws
    func getAccessToken() -> String?
    func getRefreshToken() -> String?
    func deleteTokens()
}

/// Manages secure storage of auth tokens in the macOS Keychain.
final class KeychainManager: TokenStore {
    private let service: String

    private enum Key {
        static let accessToken = "bundle_access_token"
        static let refreshToken = "bundle_refresh_token"
    }

    init(service: String = "com.bundle.auth") {
        self.service = service
    }

    func saveTokens(access: String, refresh: String) throws {
        try save(key: Key.accessToken, value: access)
        try save(key: Key.refreshToken, value: refresh)
    }

    func getAccessToken() -> String? {
        read(key: Key.accessToken)
    }

    func getRefreshToken() -> String? {
        read(key: Key.refreshToken)
    }

    func deleteTokens() {
        delete(key: Key.accessToken)
        delete(key: Key.refreshToken)
    }

    // MARK: - Private Helpers

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing item first (update pattern)
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode token data"
        case .saveFailed(let status):
            return "Keychain save failed with status: \(status)"
        }
    }
}

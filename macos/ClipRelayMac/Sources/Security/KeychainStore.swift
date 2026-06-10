// Thin wrapper around macOS Keychain Services for secure data storage and retrieval.

import Foundation
import Security

/// Abstraction over keychain storage so tests can use an in-memory store
/// instead of the real login keychain (which triggers ACL password prompts
/// for every freshly-signed test bundle).
protocol SecretStore: AnyObject {
    func data(for account: String) -> Data?
    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool
}

/// In-memory SecretStore for unit tests.
final class InMemorySecretStore: SecretStore {
    private var storage: [String: Data] = [:]

    func data(for account: String) -> Data? {
        storage[account]
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        storage[account] = data
        return true
    }
}

final class KeychainStore: SecretStore {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

}

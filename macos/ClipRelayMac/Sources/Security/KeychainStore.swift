// Thin wrapper around macOS Keychain Services for secure data storage and retrieval.

import Foundation
import Security

package final class KeychainStore: SecureDataStore {
    private let service: String
    private let usesExplicitKeychain: Bool
    private let keychain: SecKeychain?

    package init(service: String, keychainPath: String? = nil, keychainPassword: String? = nil) {
        self.service = service
        self.usesExplicitKeychain = keychainPath != nil
        self.keychain = Self.openKeychain(at: keychainPath, password: keychainPassword)
    }

    package func data(for account: String) -> Data? {
        guard let query = lookupQuery(for: account) else { return nil }
        var matchingQuery = query
        matchingQuery[kSecReturnData as String] = true
        matchingQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(matchingQuery as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    package func setData(_ data: Data, for account: String) -> Bool {
        guard let query = lookupQuery(for: account) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard var addQuery = addQuery(for: account) else { return false }
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    package func removeData(for account: String) -> Bool {
        guard let query = lookupQuery(for: account) else { return false }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func lookupQuery(for account: String) -> [String: Any]? {
        guard !usesExplicitKeychain || keychain != nil else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func addQuery(for account: String) -> [String: Any]? {
        guard !usesExplicitKeychain || keychain != nil else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain {
            query[kSecUseKeychain as String] = keychain
        }
        return query
    }

    private static func openKeychain(at path: String?, password: String?) -> SecKeychain? {
        guard let path else { return nil }

        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else { return nil }

        if let password {
            let passwordBytes = Array(password.utf8)
            let unlockStatus = passwordBytes.withUnsafeBytes { bytes in
                SecKeychainUnlock(keychain, UInt32(passwordBytes.count), bytes.baseAddress, true)
            }
            guard unlockStatus == errSecSuccess else { return nil }
        }

        return keychain
    }
}

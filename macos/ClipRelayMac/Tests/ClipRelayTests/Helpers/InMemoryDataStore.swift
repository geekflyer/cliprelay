import Foundation
@testable import ClipRelayCore

final class InMemoryDataStore: SecureDataStore {
    private var values: [String: Data] = [:]

    func data(for account: String) -> Data? {
        values[account]
    }

    @discardableResult
    func setData(_ data: Data, for account: String) -> Bool {
        values[account] = data
        return true
    }

    @discardableResult
    func removeData(for account: String) -> Bool {
        values.removeValue(forKey: account)
        return true
    }
}

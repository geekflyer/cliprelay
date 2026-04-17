import Foundation

package protocol SecureDataStore {
    func data(for account: String) -> Data?
    @discardableResult func setData(_ data: Data, for account: String) -> Bool
    @discardableResult func removeData(for account: String) -> Bool
}

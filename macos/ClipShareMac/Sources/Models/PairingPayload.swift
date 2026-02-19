import Foundation

struct PairingPayload: Codable {
    let token: String
    let serviceUUID: String
    let macPublicKey: String
}

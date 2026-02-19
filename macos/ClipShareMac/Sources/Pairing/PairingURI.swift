import Foundation

struct PairingURI {
    static func make(tokenHex: String, serviceUUID: String, macPublicKeyBase64: String) -> URL? {
        let payload = PairingPayload(token: tokenHex, serviceUUID: serviceUUID, macPublicKey: macPublicKeyBase64)
        guard let json = try? JSONEncoder().encode(payload) else { return nil }
        let encoded = json.base64EncodedString()

        var components = URLComponents()
        components.scheme = "clipshare"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "data", value: encoded)]
        return components.url
    }
}

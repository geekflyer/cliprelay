import Foundation

struct ClipboardContent: Codable {
    let hash: String
    let size: Int
    let type: String
    let payload: Data
}

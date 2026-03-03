// Lightweight model representing a known BLE peer for display in the status bar menu.

import Foundation

struct PeerSummary {
    let id: UUID
    let description: String
    var token: String?
    var deviceTagHex: String?
}

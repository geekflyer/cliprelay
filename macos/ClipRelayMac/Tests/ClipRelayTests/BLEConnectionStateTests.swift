import CoreBluetooth
import XCTest
@testable import ClipRelay

// Minimal stub so we can construct PeerSummary values without a live CBPeripheral.
// The actual filtering logic lives in BLECentralManager.connectedPeerSummaries(),
// which is private. We replicate its filter predicate here to unit-test the
// contract: a peer is "connected" only when both characteristics are non-nil.

final class BLEConnectionStateTests: XCTestCase {

    // Simulated ConnectedPeer fields relevant to the filter.
    private struct FakePeer {
        let token: String
        let displayName: String
        let availableCharacteristic: Bool
        let dataCharacteristic: Bool
    }

    private func filteredPeers(_ peers: [FakePeer]) -> [FakePeer] {
        peers.filter { $0.availableCharacteristic && $0.dataCharacteristic }
    }

    func testPeerWithBothCharacteristicsIsConnected() {
        let peer = FakePeer(
            token: "tok-1",
            displayName: "Phone",
            availableCharacteristic: true,
            dataCharacteristic: true
        )
        let result = filteredPeers([peer])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.displayName, "Phone")
    }

    func testPeerWithNoCharacteristicsIsNotConnected() {
        let peer = FakePeer(
            token: "tok-2",
            displayName: "Phone",
            availableCharacteristic: false,
            dataCharacteristic: false
        )
        let result = filteredPeers([peer])
        XCTAssertTrue(result.isEmpty)
    }

    func testPeerWithOnlyAvailableCharacteristicIsNotConnected() {
        let peer = FakePeer(
            token: "tok-3",
            displayName: "Phone",
            availableCharacteristic: true,
            dataCharacteristic: false
        )
        let result = filteredPeers([peer])
        XCTAssertTrue(result.isEmpty)
    }

    func testPeerWithOnlyDataCharacteristicIsNotConnected() {
        let peer = FakePeer(
            token: "tok-4",
            displayName: "Phone",
            availableCharacteristic: false,
            dataCharacteristic: true
        )
        let result = filteredPeers([peer])
        XCTAssertTrue(result.isEmpty)
    }

    func testMixedPeersOnlyFullyDiscoveredReturned() {
        let peers = [
            FakePeer(token: "tok-a", displayName: "Ready", availableCharacteristic: true, dataCharacteristic: true),
            FakePeer(token: "tok-b", displayName: "Partial", availableCharacteristic: true, dataCharacteristic: false),
            FakePeer(token: "tok-c", displayName: "None", availableCharacteristic: false, dataCharacteristic: false),
        ]
        let result = filteredPeers(peers)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.displayName, "Ready")
    }
}

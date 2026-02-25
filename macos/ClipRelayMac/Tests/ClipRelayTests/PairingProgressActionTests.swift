import XCTest
@testable import ClipRelay

final class PairingProgressActionTests: XCTestCase {
    func testReturnsNoneWhenNotAwaitingPairing() {
        let action = pairingProgressAction(
            awaitingNewPairingConnection: false,
            isPairingWindowShowing: false,
            connectedPeerIDs: [UUID()],
            pairingBaselineConnectedPeerIDs: []
        )

        XCTAssertEqual(action, .none)
    }

    func testCancelsPendingWhenWindowIsNotShowing() {
        let action = pairingProgressAction(
            awaitingNewPairingConnection: true,
            isPairingWindowShowing: false,
            connectedPeerIDs: [],
            pairingBaselineConnectedPeerIDs: []
        )

        XCTAssertEqual(action, .cancelPending)
    }

    func testReturnsNoneWhenNoNewPeerConnected() {
        let connectedPeerID = UUID()
        let action = pairingProgressAction(
            awaitingNewPairingConnection: true,
            isPairingWindowShowing: true,
            connectedPeerIDs: [connectedPeerID],
            pairingBaselineConnectedPeerIDs: [connectedPeerID]
        )

        XCTAssertEqual(action, .none)
    }

    func testCompletesPairingWhenNewPeerConnects() {
        let baselinePeerID = UUID()
        let newPeerID = UUID()
        let action = pairingProgressAction(
            awaitingNewPairingConnection: true,
            isPairingWindowShowing: true,
            connectedPeerIDs: [baselinePeerID, newPeerID],
            pairingBaselineConnectedPeerIDs: [baselinePeerID]
        )

        XCTAssertEqual(action, .completePairing)
    }
}

import XCTest
@testable import ClipRelay

final class LocalNetworkAddressTests: XCTestCase {

    func testReturnsIPv4OrNil() {
        let address = LocalNetworkAddress.getLocalIPv4Address()
        // On a machine with Wi-Fi, this should return a non-loopback IPv4 address.
        // On CI or machines without Wi-Fi, it may return nil.
        if let addr = address {
            XCTAssertFalse(addr.hasPrefix("127."), "Should not return loopback address")
            // Basic IPv4 format check
            let components = addr.split(separator: ".")
            XCTAssertEqual(components.count, 4, "Should be a dotted-quad IPv4 address")
        }
        // nil is acceptable if no Wi-Fi interface is available
    }
}

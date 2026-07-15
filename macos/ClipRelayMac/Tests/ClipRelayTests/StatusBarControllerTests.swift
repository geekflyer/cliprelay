import XCTest
@testable import ClipRelay

final class StatusBarControllerTests: XCTestCase {
    func testOutboundSyncIndicatorSpecMatchesExpectedKeyframeCount() {
        let spec = StatusBarController.syncIndicatorSpec(for: .outbound)

        XCTAssertEqual(spec.values.count, spec.keyTimes.count)
        XCTAssertEqual(spec.duration, 0.35, accuracy: 0.001)
        XCTAssertEqual(spec.restoreDelay, 0.4, accuracy: 0.001)
    }

    func testInboundSyncIndicatorSpecMatchesExpectedKeyframeCount() {
        let spec = StatusBarController.syncIndicatorSpec(for: .inbound)

        XCTAssertEqual(spec.values.count, spec.keyTimes.count)
        XCTAssertEqual(spec.duration, 0.65, accuracy: 0.001)
        XCTAssertEqual(spec.restoreDelay, 0.85, accuracy: 0.001)
    }
}

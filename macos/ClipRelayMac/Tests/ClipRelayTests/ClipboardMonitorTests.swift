import AppKit
import XCTest
@testable import ClipRelay

final class ClipboardMonitorTests: XCTestCase {
    func testConcealedDetection() {
        XCTAssertTrue(ClipboardMonitor.isConcealed([ClipboardMonitor.concealedType]))
        XCTAssertTrue(ClipboardMonitor.isConcealed([.string, ClipboardMonitor.concealedType]))
        XCTAssertFalse(ClipboardMonitor.isConcealed([.string, .png]))
        XCTAssertFalse(ClipboardMonitor.isConcealed([]))
        XCTAssertFalse(ClipboardMonitor.isConcealed(nil))
    }

    func testSkipSecretsDefaultsOn() {
        let key = ClipboardMonitor.skipSecretsDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(ClipboardMonitor.skipSecretsEnabled, "should default to on")

        ClipboardMonitor.skipSecretsEnabled = false
        XCTAssertFalse(ClipboardMonitor.skipSecretsEnabled)
    }
}

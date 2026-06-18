import XCTest
@testable import ClipRelay

final class LogShareExporterTests: XCTestCase {
    func testBuildShareTextIncludesDiagnosticAndUnifiedSections() {
        let text = LogShareExporter.buildShareText(
            deviceContext: [("App Version", "0.7.0 (abc123)"), ("BLE State", "connected")],
            generatedAt: Date(),
            diagnosticLog: "2026-04-11T15:42:05Z [Connection] L2CAP open error (pairing): CBErrorDomain code=14",
            logs: "log show output here"
        )

        XCTAssertTrue(text.contains("ClipRelay macOS diagnostics"))
        XCTAssertTrue(text.contains("App Version: 0.7.0 (abc123)"))
        XCTAssertTrue(text.contains("BLE State: connected"))
        XCTAssertTrue(text.contains("---- DIAGNOSTIC LOG (BLE / pairing) ----"))
        XCTAssertTrue(text.contains("L2CAP open error (pairing): CBErrorDomain code=14"))
        XCTAssertTrue(text.contains("---- UNIFIED LOGS ----"))
        XCTAssertTrue(text.contains("log show output here"))
    }

    func testBuildShareTextHandlesEmptyDiagnosticLog() {
        let text = LogShareExporter.buildShareText(
            deviceContext: [],
            generatedAt: Date(),
            diagnosticLog: "   \n  ",
            logs: ""
        )

        XCTAssertTrue(text.contains("No diagnostic log entries were recorded yet."))
    }

    func testTailKeepsRecentContentAndDropsOldest() {
        let big = "OLDEST_LINE\n" + String(repeating: "x\n", count: 250_000) // ~500k chars
        let trimmed = LogShareExporter.tail(big, maxChars: 400_000)

        XCTAssertLessThanOrEqual(trimmed.count, 400_080)
        XCTAssertTrue(trimmed.hasPrefix("[… older lines truncated"))
        XCTAssertFalse(trimmed.contains("OLDEST_LINE"))
    }

    func testTailReturnsInputWhenWithinBudget() {
        let small = "line1\nline2"
        XCTAssertEqual(LogShareExporter.tail(small, maxChars: 400_000), small)
    }
}

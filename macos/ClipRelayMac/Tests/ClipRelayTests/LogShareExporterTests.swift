import XCTest
@testable import ClipRelay

final class LogShareExporterTests: XCTestCase {
    func testBuildFileNameUsesUTCTimestamp() {
        let date = ISO8601DateFormatter().date(from: "2026-04-11T15:42:05Z")!
        XCTAssertEqual(LogShareExporter.buildFileName(for: date), "cliprelay-mac-logs-20260411-154205.txt")
    }

    func testBuildFileContentsIncludesDiagnosticAndUnifiedSections() {
        let contents = LogShareExporter.buildFileContents(
            deviceContext: [("App Version", "0.7.0 (abc123)"), ("BLE State", "connected")],
            generatedAt: Date(),
            diagnosticLog: "2026-04-11T15:42:05Z [Connection] L2CAP open error (pairing): CBErrorDomain code=14",
            logs: "log show output here"
        )

        XCTAssertTrue(contents.contains("ClipRelay macOS diagnostics"))
        XCTAssertTrue(contents.contains("App Version: 0.7.0 (abc123)"))
        XCTAssertTrue(contents.contains("BLE State: connected"))
        XCTAssertTrue(contents.contains("---- DIAGNOSTIC LOG (BLE / pairing) ----"))
        XCTAssertTrue(contents.contains("L2CAP open error (pairing): CBErrorDomain code=14"))
        XCTAssertTrue(contents.contains("---- UNIFIED LOGS ----"))
        XCTAssertTrue(contents.contains("log show output here"))
    }

    func testBuildFileContentsHandlesEmptyDiagnosticLog() {
        let contents = LogShareExporter.buildFileContents(
            deviceContext: [],
            generatedAt: Date(),
            diagnosticLog: "   \n  ",
            logs: ""
        )

        XCTAssertTrue(contents.contains("No diagnostic log entries were recorded yet."))
    }
}

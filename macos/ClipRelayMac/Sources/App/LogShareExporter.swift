import Foundation

enum LogShareExporter {
    // Shared as plain text via NSSharingServicePicker rather than a .txt file —
    // text drops straight into Mail/Messages/Notes or the pasteboard. The
    // diagnostic log is already bounded by rotation; cap each section's tail so
    // a debug-build unified-log dump can't bloat the share.
    private static let maxDiagnosticChars = 400_000
    private static let maxUnifiedLogChars = 200_000

    static func exportLogs(deviceContext: [(String, String)]) -> String {
        buildShareText(
            deviceContext: deviceContext,
            generatedAt: Date(),
            diagnosticLog: tail(DiagnosticLog.shared.currentLogText(), maxChars: maxDiagnosticChars),
            logs: tail(captureUnifiedLogs(), maxChars: maxUnifiedLogChars)
        )
    }

    private static func captureUnifiedLogs() -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style",
            "compact",
            "--last",
            "24h",
            "--predicate",
            "subsystem == \"org.cliprelay\" OR process == \"ClipRelay\"",
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return "Unable to capture unified logs: \(error.localizedDescription)"
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return """
            `log show` exited with status \(process.terminationStatus).

            \(errorOutput)

            \(output)
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return output.isEmpty ? "No recent ClipRelay unified logs were available." : output
    }

    /// Keep the most recent `maxChars`, dropping the now-partial leading line.
    static func tail(_ string: String, maxChars: Int) -> String {
        guard string.count > maxChars else { return string }
        let start = string.index(string.endIndex, offsetBy: -maxChars)
        let trimmed = string[start...]
        if let newline = trimmed.firstIndex(of: "\n") {
            return "[… older lines truncated to fit the share size limit …]\n"
                + trimmed[trimmed.index(after: newline)...]
        }
        return String(trimmed)
    }

    static func buildShareText(
        deviceContext: [(String, String)],
        generatedAt: Date,
        diagnosticLog: String,
        logs: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let contextLines = deviceContext.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        let diagnostics = diagnosticLog.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ClipRelay macOS diagnostics
        Generated: \(formatter.string(from: generatedAt))
        Included logs: ClipRelay diagnostic log (BLE/pairing trace) + unified log snapshot from the last 24 hours

        \(contextLines)

        ---- DIAGNOSTIC LOG (BLE / pairing) ----
        \(diagnostics.isEmpty ? "No diagnostic log entries were recorded yet." : diagnostics)

        ---- UNIFIED LOGS ----
        \(logs)
        """
    }
}

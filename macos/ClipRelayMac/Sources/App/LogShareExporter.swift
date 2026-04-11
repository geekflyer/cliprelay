import Foundation

enum LogShareExporter {
    private static let shareDirectoryName = "ClipRelaySharedLogs"

    static func exportLogs(deviceContext: [(String, String)]) throws -> URL {
        let now = Date()
        let shareDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(shareDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: shareDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = shareDirectory.appendingPathComponent(buildFileName(for: now), isDirectory: false)
        let contents = buildFileContents(
            deviceContext: deviceContext,
            generatedAt: now,
            logs: captureUnifiedLogs()
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
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
            "subsystem == \"org.cliprelay\"",
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Unable to capture unified logs: \(error.localizedDescription)"
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            return """
            `log show` exited with status \(process.terminationStatus).

            \(errorOutput)

            \(output)
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return output.isEmpty ? "No recent ClipRelay unified logs were available." : output
    }

    private static func buildFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "cliprelay-mac-logs-\(formatter.string(from: date)).txt"
    }

    private static func buildFileContents(
        deviceContext: [(String, String)],
        generatedAt: Date,
        logs: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let contextLines = deviceContext.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return """
        ClipRelay macOS diagnostics
        Generated: \(formatter.string(from: generatedAt))
        Included logs: ClipRelay unified log snapshot from the last 24 hours

        \(contextLines)

        ---- UNIFIED LOGS ----
        \(logs)
        """
    }
}

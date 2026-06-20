// Append-only diagnostic log persisted to a file under Application Support.
//
// `os.Logger` output is invisible to the unified log / `log show` in our SPM
// release builds, so users (and the maintainer) cannot see why BLE pairing or
// reconnection fails on shipped builds. This logger mirrors the critical BLE
// and pairing events to a rotating file that the menu-bar "Share Logs" action
// can read back, regardless of how os_log is configured.

import Foundation
import os

final class DiagnosticLog {
    static let shared = DiagnosticLog()

    /// All writes (and the consistent read in `currentLogText()`) are serialized here.
    private let queue = DispatchQueue(label: "org.cliprelay.diagnostics")
    /// Mirror to os.Logger too, so Console still works during local development.
    private let logger = Logger(subsystem: "org.cliprelay", category: "Diagnostics")

    /// Rotate once the active file passes this size; one previous file is kept,
    /// so the shared log is bounded to roughly twice this.
    private let maxBytes: UInt64 = 512_000

    private let fileURL: URL?
    private let previousFileURL: URL?
    private let timestampFormatter: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.timestampFormatter = formatter

        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent("ClipRelay", isDirectory: true)

        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.fileURL = directory?.appendingPathComponent("diagnostics.log", isDirectory: false)
        self.previousFileURL = directory?.appendingPathComponent("diagnostics.1.log", isDirectory: false)

        // Stamp every session with app + OS context so a shared log is self-describing.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        log("ClipRelay \(version) (\(build)) — \(osVersion) — diagnostics session start", category: "App")
    }

    /// Record one diagnostic line. Safe to call from any thread; file I/O is async.
    func log(_ message: String, category: String = "App") {
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(timestampFormatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    /// The full diagnostic history (rotated + current), oldest first. Returns an
    /// empty string when nothing has been logged yet.
    func currentLogText() -> String {
        queue.sync {
            let previous = previousFileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let current = fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return previous + current
        }
    }

    // MARK: - File writing (queue-only)

    private func append(_ line: String) {
        guard let fileURL, let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        guard let fileURL, let previousFileURL else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value, size > maxBytes else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: previousFileURL)
        try? fm.moveItem(at: fileURL, to: previousFileURL)
    }
}

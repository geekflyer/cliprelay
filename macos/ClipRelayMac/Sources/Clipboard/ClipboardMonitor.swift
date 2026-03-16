// Polls the macOS pasteboard for changes and fires a callback when new content is detected.

import AppKit
import CryptoKit

enum ClipboardContent {
    case text(String)
    case image(Data, String)  // (data, mimeType e.g. "image/png")
}

final class ClipboardMonitor {
    static let defaultPollInterval: TimeInterval = {
        guard
            let value = ProcessInfo.processInfo.environment["CLIPRELAY_POLL_INTERVAL_MS"],
            let milliseconds = Double(value),
            milliseconds >= 100
        else {
            return 0.5
        }
        return milliseconds / 1000
    }()

    /// Maximum image size: 10 MB
    private static let maxImageSize = 10_485_760

    private let pasteboard = NSPasteboard.general
    private let onChange: (ClipboardContent) -> Void
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastHash: String?

    init(pollInterval: TimeInterval = ClipboardMonitor.defaultPollInterval, onChange: @escaping (ClipboardContent) -> Void) {
        self.pollInterval = pollInterval
        self.onChange = onChange
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Check for image first (PNG, then TIFF)
        if let imageData = pasteboard.data(forType: .png), !imageData.isEmpty {
            guard imageData.count <= Self.maxImageSize else { return }
            let digest = SHA256.hash(data: imageData)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            guard hash != lastHash else { return }
            lastHash = hash
            onChange(.image(imageData, "image/png"))
            return
        }

        if let imageData = pasteboard.data(forType: .tiff), !imageData.isEmpty {
            guard imageData.count <= Self.maxImageSize else { return }
            let digest = SHA256.hash(data: imageData)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            guard hash != lastHash else { return }
            lastHash = hash
            onChange(.image(imageData, "image/tiff"))
            return
        }

        // Fall back to text
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= 102_400 else { return }

        let digest = SHA256.hash(data: Data(text.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        guard hash != lastHash else { return }
        lastHash = hash
        onChange(.text(text))
    }
}

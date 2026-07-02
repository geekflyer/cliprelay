// Polls the macOS pasteboard for changes and fires a callback when new text or image is detected.

import AppKit
import CryptoKit

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

    /// De-facto standard marker password managers (Bitwarden, 1Password, …) put on the
    /// pasteboard for secret copies. See nspasteboard.org and issue #70.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static let skipSecretsDefaultsKey = "skipPasswordsAndSecrets"

    /// When on, concealed (password-manager) copies are not synced. Defaults to on.
    static var skipSecretsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: skipSecretsDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: skipSecretsDefaultsKey) }
    }

    /// True if the pasteboard carries the concealed marker. Pure for testability.
    static func isConcealed(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        types?.contains(concealedType) ?? false
    }

    private let pasteboard = NSPasteboard.general
    private let onChange: (String) -> Void
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastHash: String?

    /// Callback for image changes: (imageData, contentType, hash)
    var onImageChange: ((Data, String, String) -> Void)?

    init(pollInterval: TimeInterval = ClipboardMonitor.defaultPollInterval, onChange: @escaping (String) -> Void) {
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

        // Don't sync password-manager / secret copies that mark themselves concealed (#70).
        // Check every item's types: pasteboard.types only reflects the first item.
        if Self.skipSecretsEnabled,
           Self.isConcealed((pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap(\.types)) {
            // Clear the dedup hash so re-copying the previous content still syncs.
            lastHash = nil
            return
        }

        // Images take priority over text
        if let (imageData, contentType) = pasteboardImage(pasteboard) {
            let digest = SHA256.hash(data: imageData)
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            guard hash != lastHash else { return }
            lastHash = hash
            onImageChange?(imageData, contentType, hash)
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= 102_400 else { return }

        let digest = SHA256.hash(data: Data(text.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        guard hash != lastHash else { return }
        lastHash = hash
        onChange(text)
    }

    /// Returns (imageData, contentType) or nil. TIFF is converted to PNG per spec.
    private func pasteboardImage(_ pasteboard: NSPasteboard) -> (Data, String)? {
        let maxSize = 10_485_760 // 10 MB
        if let png = pasteboard.data(forType: .png), png.count <= maxSize {
            return (png, "image/png")
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")),
           jpeg.count <= maxSize {
            return (jpeg, "image/jpeg")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmapRep = NSBitmapImageRep(data: tiff),
           let png = bitmapRep.representation(using: .png, properties: [:]),
           png.count <= maxSize {
            return (png, "image/png")
        }
        return nil
    }
}

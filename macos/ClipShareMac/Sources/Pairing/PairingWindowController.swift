import AppKit
import CoreImage

final class PairingWindowController {
    private var window: NSWindow?
    private var windowDelegate: WindowCloseHandler?
    var onDidClose: (() -> Void)?

    var isShowing: Bool {
        window?.isVisible == true
    }

    func showPairingQR(uri: URL) {
        let content = makeContentView(uri: uri)

        if let existing = window {
            existing.contentView = content
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentRect = NSRect(x: 0, y: 0, width: 280, height: 320)
        let w = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Pair New Device"
        w.contentView = content
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        let delegate = WindowCloseHandler { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            self?.onDidClose?()
        }
        windowDelegate = delegate
        w.delegate = delegate

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func makeContentView(uri: URL) -> NSView {
        let qrImage = generateQRCode(from: uri.absoluteString)

        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
        imageView.image = qrImage
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: "Scan this QR code with the\nGreenPaste Android app")
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13)
        label.maximumNumberOfLines = 2

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return stack
    }
}

private final class WindowCloseHandler: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

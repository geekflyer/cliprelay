import AppKit
import CoreImage

final class PairingWindowController {
    private var window: NSWindow?

    func showPairingQR(uri: URL) {
        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 500)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pair New Device"

        let contentView = NSView(frame: contentRect)

        let titleLabel = NSTextField(labelWithString: "Scan this QR from Android")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 24, y: 454, width: 360, height: 24)
        contentView.addSubview(titleLabel)

        let qrView = NSImageView(frame: NSRect(x: 60, y: 140, width: 300, height: 300))
        qrView.imageAlignment = .alignCenter
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.image = makeQRCodeImage(from: uri.absoluteString)
        contentView.addSubview(qrView)

        let hintLabel = NSTextField(labelWithString: "The code carries token, service UUID, and public key.")
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 24, y: 104, width: 372, height: 18)
        contentView.addSubview(hintLabel)

        let uriLabel = NSTextField(wrappingLabelWithString: uri.absoluteString)
        uriLabel.frame = NSRect(x: 24, y: 20, width: 372, height: 72)
        uriLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        uriLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(uriLabel)

        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func makeQRCodeImage(from value: String) -> NSImage? {
        guard
            let data = value.data(using: .utf8),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else {
            return nil
        }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

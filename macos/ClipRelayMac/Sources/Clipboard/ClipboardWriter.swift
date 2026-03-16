// Writes received text or images to the macOS system pasteboard.

import AppKit

final class ClipboardWriter {
    func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func writeImage(_ data: Data, type: NSPasteboard.PasteboardType) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
    }
}

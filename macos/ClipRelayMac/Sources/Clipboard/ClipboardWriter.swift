// Writes received text to the macOS system pasteboard.

import AppKit

final class ClipboardWriter {
    func writeText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func writeImage(_ data: Data, contentType: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pasteboardType: NSPasteboard.PasteboardType = contentType.contains("jpeg")
            ? NSPasteboard.PasteboardType("public.jpeg")
            : .png
        pasteboard.setData(data, forType: pasteboardType)
    }
}

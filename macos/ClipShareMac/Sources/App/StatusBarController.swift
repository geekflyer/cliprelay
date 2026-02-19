import AppKit

final class StatusBarController {
    var onPairRequested: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
    private lazy var pairMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Pair in Bluetooth Settings", action: #selector(handlePairRequest), keyEquivalent: "p")
        item.target = self
        return item
    }()

    init() {
        if let button = statusItem.button {
            button.title = "Clip"
        }

        menu.addItem(statusMenuItem)
        menu.addItem(pairMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        statusItem.menu = menu
    }

    func setConnected(_ connected: Bool) {
        statusMenuItem.title = connected ? "Status: Connected" : "Status: Disconnected"
    }

    @objc
    private func handlePairRequest() {
        onPairRequested?()
    }
}

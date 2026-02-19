import AppKit

final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")

    init() {
        if let button = statusItem.button {
            button.title = "Clip"
        }

        menu.addItem(statusMenuItem)
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
}

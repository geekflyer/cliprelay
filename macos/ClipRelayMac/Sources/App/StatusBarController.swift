// Manages the macOS menu bar icon, status dot, and dropdown menu for peer management.

import AppKit
import Foundation
import QuartzCore

final class StatusBarController {
    var onPairNewDeviceRequested: (() -> Void)?
    var onForgetDeviceRequested: ((String) -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var isLaunchAtLoginEnabled: (() -> Bool)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var connectedPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []

    private static let brandAqua = NSColor(red: 0, green: 1, blue: 0.835, alpha: 1) // #00FFD5

    private lazy var connectedDot: NSImage = makeStatusDot(color: Self.brandAqua)
    private lazy var disconnectedDot: NSImage = makeStatusDot(color: .tertiaryLabelColor)

    private var baseStatusBarImage: NSImage?
    private var syncPulseTimer: Timer?

    init() {
        baseStatusBarImage = loadStatusBarIcon()
        updateStatusBarIcon()
        renderMenu()
    }

    private func loadStatusBarIcon() -> NSImage? {
        if let bundlePath = Bundle.main.path(forResource: "StatusBarIcon", ofType: "png") {
            let image = NSImage(contentsOfFile: bundlePath)
            image?.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        guard let base = baseStatusBarImage else {
            button.title = "GP"
            return
        }
        if !connectedPeers.isEmpty {
            let aqua = base.colorized(with: Self.brandAqua)
            aqua.isTemplate = false
            button.image = aqua
        } else {
            let template = base.copy() as! NSImage
            template.isTemplate = true
            button.image = template
        }
    }

    func setConnectedPeers(_ peers: [PeerSummary]) {
        connectedPeers = peers
        updateStatusBarIcon()
        renderMenu()
    }

    func setTrustedPeers(_ peers: [PeerSummary]) {
        trustedPeers = peers
        renderMenu()
    }


    /// Briefly pulses the status bar icon to indicate a clipboard sync.
    func flashSyncIndicator() {
        guard let button = statusItem.button, let base = baseStatusBarImage else { return }

        // Cancel any in-progress pulse
        syncPulseTimer?.invalidate()

        // Show bright highlight icon
        let highlight = base.colorized(with: .systemYellow)
        highlight.isTemplate = false
        button.image = highlight

        // Enable layer-backed view for Core Animation
        button.wantsLayer = true
        if let layer = button.layer {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1.0, 1.3, 1.0]
            pulse.keyTimes = [0, 0.4, 1.0]
            pulse.duration = 0.35
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "syncPulse")
        }

        // Restore normal icon after the animation completes
        syncPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
    }

    // MARK: - Menu rendering

    private func renderMenu() {
        menu.removeAllItems()

        renderTrustedDevicesSection()
        menu.addItem(NSMenuItem.separator())

        let pairItem = NSMenuItem(
            title: "Pair New Device\u{2026}",
            action: #selector(handlePairNewDevice),
            keyEquivalent: "n"
        )
        pairItem.target = self
        menu.addItem(pairItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(handleToggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        if isLaunchAtLoginEnabled?() == true {
            launchItem.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "enabled")
        }
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "ClipRelay v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let websiteItem = NSMenuItem(
            title: "Visit Website\u{2026}",
            action: #selector(handleVisitWebsite),
            keyEquivalent: ""
        )
        websiteItem.target = self
        menu.addItem(websiteItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit ClipRelay",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func renderTrustedDevicesSection() {
        let header = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if trustedPeers.isEmpty {
            let empty = NSMenuItem(title: "  No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let connectedIDs = Set(connectedPeers.map(\.id))

        for peer in trustedPeers {
            let isConnected = connectedIDs.contains(peer.id)

            let title: String
            if let tag = peer.deviceTagHex {
                title = "\(peer.description)  [Pairing: \(tag)]"
            } else {
                title = peer.description
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = isConnected ? connectedDot : disconnectedDot
            item.isEnabled = true

            let submenu = NSMenu()
            let forgetItem = NSMenuItem(
                title: "Forget Device",
                action: #selector(handleForgetDevice(_:)),
                keyEquivalent: ""
            )
            forgetItem.target = self
            forgetItem.representedObject = peer.secret
            submenu.addItem(forgetItem)

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    // MARK: - Status dot

    private func makeStatusDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Actions

    @objc
    private func handlePairNewDevice() {
        onPairNewDeviceRequested?()
    }

    @objc
    private func handleToggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
        renderMenu()
    }

    @objc
    private func handleVisitWebsite() {
        if let url = URL(string: "https://cliprelay.pages.dev") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func handleForgetDevice(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        onForgetDeviceRequested?(token)
    }
}

// MARK: - NSImage tinting

private extension NSImage {
    /// Returns a copy of the image with every opaque pixel replaced by `color`.
    func colorized(with color: NSColor) -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.setBlendMode(.destinationIn)
            ctx.draw(cgImage, in: rect)
            return true
        }
    }
}

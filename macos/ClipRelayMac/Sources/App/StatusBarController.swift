// Manages the macOS menu bar icon, status dot, and dropdown menu for peer management.

import AppKit
import Foundation
import QuartzCore
import Sparkle
import UserNotifications

final class StatusBarController {
    var onPairNewDeviceRequested: (() -> Void)?
    var onForgetDeviceRequested: ((String) -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var isLaunchAtLoginEnabled: (() -> Bool)?
    var onToggleImageSync: (() -> Void)?
    var isImageSyncEnabled: (() -> Bool)?
    var onToggleSkipSecrets: (() -> Void)?
    var isSkipSecretsEnabled: (() -> Bool)?
    var isDeviceConnected: (() -> Bool)?
    var bleStateProvider: (() -> String)?

    private var availableUpdateVersion: String?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let updaterController: SPUStandardUpdaterController

    private var connectedPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []
    private var bluetoothWarning: String?
    private var bluetoothWarningAction: (() -> Void)?

    private static let brandAqua = NSColor(red: 0, green: 1, blue: 0.835, alpha: 1) // #00FFD5

    private lazy var connectedDot: NSImage = makeStatusDot(color: Self.brandAqua)
    private lazy var disconnectedDot: NSImage = makeStatusDot(color: .tertiaryLabelColor)

    private var baseStatusBarImage: NSImage?
    private var syncPulseTimer: Timer?

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
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
        if bluetoothWarning != nil {
            // A Bluetooth problem means the app is inactive. Keep the normal template glyph
            // (so it renders the same soft gray as idle, not a heavier solid black) and
            // overlay a yellow warning badge on top.
            let template = base.copy() as! NSImage
            template.isTemplate = true
            button.image = template
            showWarningBadge(on: button)
        } else if !connectedPeers.isEmpty {
            hideWarningBadge(on: button)
            let aqua = base.colorized(with: Self.brandAqua)
            aqua.isTemplate = false
            button.image = aqua
        } else {
            hideWarningBadge(on: button)
            let template = base.copy() as! NSImage
            template.isTemplate = true
            button.image = template
        }
    }

    private static let warningBadgeLayerName = "clipRelayWarningBadge"

    /// Overlays a small yellow "!" badge on the top-right of the status item. Drawn as a
    /// layer (not composited into the image) so the glyph keeps its template appearance and
    /// the badge never intercepts the menu click.
    private func showWarningBadge(on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }

        let badge: CALayer
        if let existing = host.sublayers?.first(where: { $0.name == Self.warningBadgeLayerName }) {
            badge = existing
        } else {
            badge = CALayer()
            badge.name = Self.warningBadgeLayerName
            host.addSublayer(badge)
        }

        let pointSize: CGFloat = 9
        let scale = button.window?.backingScaleFactor ?? 2
        badge.contents = makeWarningBadgeImage(pixelDiameter: pointSize * scale)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        badge.contentsGravity = .resizeAspect
        badge.contentsScale = scale

        // Sit over the top-right corner of the centered 18pt glyph. The button's backing
        // layer is flipped (top-left origin), so the glyph's top edge is the smaller y.
        let bounds = button.bounds
        let glyph: CGFloat = 18
        let glyphMaxX = (bounds.width + glyph) / 2
        let glyphMinY = (bounds.height - glyph) / 2
        badge.frame = CGRect(x: glyphMaxX - pointSize + 1, y: glyphMinY - 1,
                             width: pointSize, height: pointSize)
    }

    private func hideWarningBadge(on button: NSStatusBarButton) {
        button.layer?.sublayers?
            .first { $0.name == Self.warningBadgeLayerName }?
            .removeFromSuperlayer()
    }

    /// A yellow disc with a dark "!" — drawn proportionally so it stays crisp at any scale.
    private func makeWarningBadgeImage(pixelDiameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: pixelDiameter, height: pixelDiameter), flipped: false) { rect in
            let w = rect.width
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: rect).fill()

            NSColor.black.setFill()
            let stemW = w * 0.16
            let stem = NSRect(x: rect.midX - stemW / 2, y: rect.midY - w * 0.03, width: stemW, height: w * 0.32)
            NSBezierPath(roundedRect: stem, xRadius: stemW / 2, yRadius: stemW / 2).fill()
            let dotD = w * 0.18
            let dot = NSRect(x: rect.midX - dotD / 2, y: rect.midY - w * 0.30, width: dotD, height: dotD)
            NSBezierPath(ovalIn: dot).fill()
            return true
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

    func setBluetoothWarning(_ warning: String?, action: (() -> Void)? = nil) {
        bluetoothWarning = warning
        bluetoothWarningAction = action
        updateStatusBarIcon()
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

    func setAvailableUpdateVersion(_ version: String?) {
        availableUpdateVersion = version
        renderMenu()
    }

    private func renderMenu() {
        menu.removeAllItems()

        if let bluetoothWarning {
            let hasAction = bluetoothWarningAction != nil
            let warningItem = NSMenuItem(
                title: bluetoothWarning,
                action: hasAction ? #selector(handleBluetoothWarningSelected) : nil,
                keyEquivalent: ""
            )
            let warningSymbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "warning")
            // Two palette colors. The symbol's first layer is the exclamation, second is the
            // triangle, so order them black then yellow for a yellow triangle + black mark.
            warningItem.image = warningSymbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow])
            )
            warningItem.target = self
            warningItem.isEnabled = hasAction
            menu.addItem(warningItem)
            menu.addItem(NSMenuItem.separator())
        }

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
            launchItem.state = .on
        }
        menu.addItem(launchItem)

        let deviceConnected = isDeviceConnected?() ?? false
        let imageSyncItem = NSMenuItem(
            title: "Image Sync (experimental)",
            action: deviceConnected ? #selector(handleToggleImageSync) : nil,
            keyEquivalent: ""
        )
        imageSyncItem.target = self
        if !deviceConnected {
            imageSyncItem.isEnabled = false
        } else if isImageSyncEnabled?() == true {
            imageSyncItem.state = .on
        }
        menu.addItem(imageSyncItem)

        let skipSecretsItem = NSMenuItem(
            title: "Don\u{2019}t Sync Passwords & Secrets",
            action: #selector(handleToggleSkipSecrets),
            keyEquivalent: ""
        )
        skipSecretsItem.target = self
        skipSecretsItem.toolTip = """
        When on, clipboard copies that an app marks as secret (concealed) are not sent to \
        your phone — so passwords stay on this Mac. Works with password managers that flag \
        copies as concealed, such as Bitwarden, 1Password and KeePassXC. \
        Note: copies made from browser extensions aren't flagged and will still sync.
        """
        if isSkipSecretsEnabled?() == true {
            skipSecretsItem.state = .on
        }
        menu.addItem(skipSecretsItem)

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

        let supportItem = NSMenuItem(title: "Feedback & Support", action: nil, keyEquivalent: "")
        let supportMenu = NSMenu()
        let issueItem = NSMenuItem(title: "Report Issue on GitHub\u{2026}", action: #selector(handleOpenGitHubIssue), keyEquivalent: "")
        issueItem.target = self
        supportMenu.addItem(issueItem)
        let emailItem = NSMenuItem(title: "Email Support\u{2026}", action: #selector(handleOpenEmail), keyEquivalent: "")
        emailItem.target = self
        supportMenu.addItem(emailItem)
        let copyLogsItem = NSMenuItem(title: "Copy Diagnostic Logs to Clipboard", action: #selector(handleCopyLogs), keyEquivalent: "")
        copyLogsItem.target = self
        supportMenu.addItem(copyLogsItem)
        supportMenu.addItem(NSMenuItem.separator())
        let discussionsItem = NSMenuItem(title: "Community Discussions\u{2026}", action: #selector(handleOpenDiscussions), keyEquivalent: "")
        discussionsItem.target = self
        supportMenu.addItem(discussionsItem)
        supportItem.submenu = supportMenu
        menu.addItem(supportItem)

        let updateTitle: String
        if let version = availableUpdateVersion {
            updateTitle = "Update Available (\(version))"
        } else {
            updateTitle = "Check for Updates\u{2026}"
        }
        let checkForUpdatesItem = NSMenuItem(title: updateTitle, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        let autoUpdateItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(handleToggleAutoUpdates),
            keyEquivalent: ""
        )
        autoUpdateItem.target = self
        if updaterController.updater.automaticallyChecksForUpdates {
            autoUpdateItem.state = .on
        }
        menu.addItem(autoUpdateItem)

        let betaItem = NSMenuItem(
            title: "Beta Channel",
            action: #selector(handleToggleBetaUpdates),
            keyEquivalent: ""
        )
        betaItem.target = self
        if isBetaChannelEnabled {
            betaItem.state = .on
        }
        menu.addItem(betaItem)

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
    private func handleBluetoothWarningSelected() {
        bluetoothWarningAction?()
    }

    @objc
    private func handleToggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
        renderMenu()
    }

    @objc
    private func handleToggleImageSync() {
        onToggleImageSync?()
        renderMenu()
    }

    @objc
    private func handleToggleSkipSecrets() {
        onToggleSkipSecrets?()
        renderMenu()
    }

    @objc
    private func handleVisitWebsite() {
        if let url = URL(string: "https://cliprelay.org") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func handleOpenGitHubIssue() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "- **\($0.0):** \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "https://github.com/geekflyer/cliprelay/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "from-app"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc
    private func handleOpenEmail() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "mailto:info@cliprelay.org")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ClipRelay Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc
    private func handleCopyLogs() {
        let context = deviceContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = LogShareExporter.exportLogs(deviceContext: context)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                // The clipboard monitor caps synced text at 100 KB, so the full
                // log dump stays local and is not pushed to paired devices.
                Self.notifyLogsCopied(byteCount: text.utf8.count)
            }
        }
    }

    private static func notifyLogsCopied(byteCount: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let kb = max(1, byteCount / 1024)
        let content = UNMutableNotificationContent()
        content.title = "Logs copied to clipboard"
        content.body = "\(kb) KB ready to paste into a bug report."
        let request = UNNotificationRequest(identifier: "logs-copied", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @objc
    private func handleOpenDiscussions() {
        if let url = URL(string: "https://github.com/geekflyer/cliprelay/discussions") {
            NSWorkspace.shared.open(url)
        }
    }

    private func deviceContext() -> [(String, String)] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var model = "Unknown Mac"
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var machine = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &machine, &size, nil, 0) == 0 {
                model = String(cString: machine)
            }
        }
        let bleState = bleStateProvider?() ?? "unknown"
        #if DEBUG
        let buildType = "debug"
        #else
        let buildType = "release"
        #endif
        let flags = [
            "imageSync=\(isImageSyncEnabled?() ?? false)",
            "skipSecrets=\(isSkipSecretsEnabled?() ?? true)",
            "autoUpdate=\(updaterController.updater.automaticallyChecksForUpdates)",
            "betaChannel=\(isBetaChannelEnabled)",
        ].joined(separator: ", ")
        return [
            ("App Version", "\(version) (\(build)) [\(buildType)]"),
            ("OS", osString),
            ("Device", model),
            ("BLE State", bleState),
            ("Paired Devices", "\(trustedPeers.count) (\(connectedPeers.count) connected)"),
            ("Flags", flags),
        ]
    }

    @objc
    private func handleToggleAutoUpdates() {
        updaterController.updater.automaticallyChecksForUpdates.toggle()
        renderMenu()
    }

    private var isBetaChannelEnabled: Bool {
        let channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        return channels.contains("beta")
    }

    @objc
    private func handleToggleBetaUpdates() {
        var channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        if isBetaChannelEnabled {
            channels.removeAll { $0 == "beta" }
        } else {
            channels.append("beta")
        }
        if channels.isEmpty {
            UserDefaults.standard.removeObject(forKey: "SUDefaultChannels")
        } else {
            UserDefaults.standard.set(channels, forKey: "SUDefaultChannels")
        }
        renderMenu()
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

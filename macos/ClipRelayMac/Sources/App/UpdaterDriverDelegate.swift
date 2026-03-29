// Sparkle user driver delegate for this menu-bar-only (LSUIElement) app.
// When a scheduled update is found, Sparkle creates its dialog behind other
// windows and we post a system notification. Tapping the notification brings
// the Sparkle dialog to the foreground.

import AppKit
import Sparkle
import UserNotifications

private let updateNotificationID = "sparkle-update-available"

final class UpdaterDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Set when a background check finds an update; cleared when the session ends.
    private(set) var availableUpdateVersion: String? {
        didSet { onUpdateAvailabilityChanged?() }
    }
    /// Called when availableUpdateVersion changes so the menu can refresh.
    var onUpdateAvailabilityChanged: (() -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // When handleShowingUpdate is false the dialog is already visible
        // from a previous reminder — nothing to do.
        guard handleShowingUpdate else { return }

        availableUpdateVersion = update.displayVersionString

        // Only post a notification for scheduled checks. User-initiated
        // checks (menu item) are shown in focus by Sparkle directly.
        guard !state.userInitiated else { return }

        let content = UNMutableNotificationContent()
        content.title = "ClipRelay Update Available"
        content.body = "Version \(update.displayVersionString) is ready to install."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: updateNotificationID,
            content: content,
            trigger: nil
        )

        // If notifications aren't authorized, fall back to bringing the
        // Sparkle dialog forward directly.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                UNUserNotificationCenter.current().add(request)
            } else {
                DispatchQueue.main.async {
                    Self.bringSparkleDialogToFront()
                }
            }
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // User interacted with the Sparkle dialog directly — dismiss our notification.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [updateNotificationID]
        )
    }

    /// Temporarily switches to a regular activation policy and brings the
    /// key window to the front. `ignoringOtherApps` is required because
    /// `NSApp.activate()` (macOS 14+) does not reliably bring windows forward
    /// for apps that were LSUIElement/accessory moments earlier.
    static func bringSparkleDialogToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdateVersion = nil
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [updateNotificationID]
        )
    }
}

// MARK: - Notification tap handling

extension UpdaterDriverDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == updateNotificationID,
           availableUpdateVersion != nil {
            Self.bringSparkleDialogToFront()
        }
        completionHandler()
    }

    // Show update notifications as banners even when the app is in the foreground.
    // Other notifications (e.g. clipboard-received) keep their default behavior.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier == updateNotificationID {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }
}

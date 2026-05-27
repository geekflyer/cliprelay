// Posts macOS user notifications when clipboard text or Android notifications are received.

import Foundation
import os
import UserNotifications

private let notifLogger = Logger(subsystem: "com.andromeda.NotiSync", category: "Notifications")

final class ReceiveNotificationManager {
    /// Called on the main thread whenever a new notification is appended to NotificationLog.
    var onNotificationLogged: (() -> Void)?

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            notifLogger.error("No bundle identifier — skipping notification auth")
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            notifLogger.info("Current notification status: \(String(describing: settings.authorizationStatus.rawValue))")
            guard settings.authorizationStatus == .notDetermined else {
                notifLogger.info("Notification auth already decided (\(settings.authorizationStatus.rawValue)), skipping prompt")
                return
            }
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error {
                        notifLogger.error("Notification auth error: \(error)")
                    } else {
                        notifLogger.info("Notification auth granted: \(granted)")
                    }
                }
            }
        }
    }

    func postClipboardReceived(text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let preview = String(text.prefix(80))
        let content = UNMutableNotificationContent()
        content.title = "Clipboard received from Android"
        content.body = preview
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "clipboard-received",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func postAndroidNotification(appName: String, title: String, text: String, iconData: Data?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard NotificationFilterStore.shared.shouldShow(appName: appName, title: title, body: text) else {
            notifLogger.debug("Notification from \(appName) suppressed by filter")
            return
        }

        // Record in the recent-notifications log (used by menu bar history).
        NotificationLog.shared.append(appName: appName, title: title, body: text)
        DispatchQueue.main.async { self.onNotificationLogged?() }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? appName : title
        if !title.isEmpty && !appName.isEmpty {
            content.subtitle = appName
        }
        // No hard truncation — let macOS decide how much to surface in the banner.
        // Notification Centre shows the full body on expand.
        content.body = text
        content.sound = .default

        if let iconData {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            do {
                try iconData.write(to: tmpURL)
                let attachment = try UNNotificationAttachment(identifier: "icon", url: tmpURL, options: nil)
                content.attachments = [attachment]
            } catch {
                notifLogger.warning("Could not attach icon: \(error)")
            }
        }

        // Include the body in the hash so two messages from the same contact
        // (same app + same title) each get their own notification instead of
        // the second replacing the first.
        let identifier = "android-\(appName)-\(title)-\(text.prefix(80))".hash.description
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifLogger.error("Failed to post Android notification: \(error)")
            }
        }
    }
}

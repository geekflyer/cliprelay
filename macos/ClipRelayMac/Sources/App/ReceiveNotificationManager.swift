// Posts macOS user notifications when clipboard text or Android notifications are received.

import Foundation
import os
import UserNotifications

private let notifLogger = Logger(subsystem: "org.cliprelay", category: "Notifications")

final class ReceiveNotificationManager {
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

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? appName : title
        if !title.isEmpty && !appName.isEmpty {
            content.subtitle = appName
        }
        content.body = String(text.prefix(200))
        content.sound = .default

        if let iconData {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".png")
            do {
                try iconData.write(to: tmpURL)
                let attachment = try UNNotificationAttachment(identifier: "icon", url: tmpURL, options: nil)
                content.attachments = [attachment]
                try? FileManager.default.removeItem(at: tmpURL)
            } catch {
                notifLogger.warning("Could not attach icon: \(error)")
            }
        }

        let identifier = "android-notification-\(appName)-\(title)".hash.description
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifLogger.error("Failed to post Android notification: \(error)")
            }
        }
    }
}

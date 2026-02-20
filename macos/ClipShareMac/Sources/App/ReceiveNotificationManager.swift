import Foundation
import UserNotifications

final class ReceiveNotificationManager {
    func requestAuthorization() {
        // Delay to avoid crash when UNUserNotificationCenter is accessed
        // before the app bundle is fully initialized.
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func postClipboardReceived(text: String) {
        let preview = String(text.prefix(80))
        let content = UNMutableNotificationContent()
        content.title = "Clipboard received from Android"
        content.body = preview
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

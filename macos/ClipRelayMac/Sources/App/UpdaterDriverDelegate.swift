// Sparkle user driver delegate: enables gentle reminders so update alerts
// appear in the foreground for this menu-bar-only (LSUIElement) app.

import AppKit
import Sparkle

final class UpdaterDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

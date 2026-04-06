// Sparkle updater delegate that controls which appcast channels are visible.
// When the user enables "Beta Updates", this returns {"beta"} so Sparkle
// includes beta-channel items. Otherwise it returns an empty set (default only).

import Foundation
import Sparkle

final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        return Set(channels)
    }
}

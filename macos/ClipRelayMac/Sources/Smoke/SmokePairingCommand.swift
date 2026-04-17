import Foundation

package enum SmokePairingCommand {
    package static func run(arguments: [String], pairingManager: PairingManager? = nil) -> Int32 {
        let pairingManager = pairingManager ?? defaultPairingManager()

        if arguments.contains("--smoke-import-pairing") {
            return runImport(arguments: arguments, pairingManager: pairingManager)
        }

        if arguments.contains("--smoke-remove-pairing") {
            return runRemove(arguments: arguments, pairingManager: pairingManager)
        }

        fputs("Usage: ClipRelaySmokeCLI --smoke-import-pairing --token TOKEN [--name NAME] | --smoke-remove-pairing --token TOKEN\n", stderr)
        return 2
    }

    private static func runImport(arguments: [String], pairingManager: PairingManager) -> Int32 {
        guard let token = value(for: "--token", in: arguments) else {
            fputs("Missing --token for --smoke-import-pairing\n", stderr)
            return 2
        }

        guard isHexToken(token) else {
            fputs("Invalid token. Expected 64-char hex string.\n", stderr)
            return 2
        }

        let displayName = value(for: "--name", in: arguments) ?? "Smoke Test Android"
        let paired = PairedDevice(
            sharedSecret: token.lowercased(),
            displayName: displayName,
            datePaired: Date()
        )

        guard pairingManager.addDevice(paired) else {
            fputs("Failed to persist pairing token.\n", stderr)
            return 1
        }
        print("Imported pairing token for \(displayName)")
        return 0
    }

    private static func runRemove(arguments: [String], pairingManager: PairingManager) -> Int32 {
        guard let token = value(for: "--token", in: arguments) else {
            fputs("Missing --token for --smoke-remove-pairing\n", stderr)
            return 2
        }

        guard isHexToken(token) else {
            fputs("Invalid token. Expected 64-char hex string.\n", stderr)
            return 2
        }

        guard pairingManager.removeDevice(secret: token.lowercased()) else {
            fputs("Failed to persist pairing removal.\n", stderr)
            return 1
        }
        print("Removed pairing token")
        return 0
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private static func isHexToken(_ token: String) -> Bool {
        if token.count != 64 { return false }
        return token.allSatisfy { ch in
            ("0"..."9").contains(String(ch)) ||
            ("a"..."f").contains(String(ch)) ||
            ("A"..."F").contains(String(ch))
        }
    }

    private static func defaultPairingManager() -> PairingManager {
        if let keychainPath = smokeKeychainPath() {
            return PairingManager(
                store: ShellSecureDataStore(
                    service: keychainService(),
                    keychainPath: keychainPath,
                    keychainPassword: smokeKeychainPassword()
                )
            )
        }

        return PairingManager()
    }

    private static func keychainService() -> String {
        ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_SERVICE"] ?? "cliprelay"
    }

    private static func smokeKeychainPath() -> String? {
        ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_PATH"]
    }

    private static func smokeKeychainPassword() -> String? {
        ProcessInfo.processInfo.environment["CLIPRELAY_PAIRING_KEYCHAIN_PASSWORD"]
    }
}

// CLI subcommands for automated smoke testing (import/remove pairing tokens from command line).

import Foundation

enum SmokeAutomationCLI {
    static func runIfRequested(arguments: [String]) -> Int32? {
        if arguments.contains("--smoke-import-pairing") {
            return runImport(arguments: arguments)
        }

        if arguments.contains("--smoke-remove-pairing") {
            return runRemove(arguments: arguments)
        }

        return nil
    }

    private static func runImport(arguments: [String]) -> Int32 {
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

        PairingManager().addDevice(paired)
        print("Imported pairing token for \(displayName)")
        return 0
    }

    private static func runRemove(arguments: [String]) -> Int32 {
        guard let token = value(for: "--token", in: arguments) else {
            fputs("Missing --token for --smoke-remove-pairing\n", stderr)
            return 2
        }

        guard isHexToken(token) else {
            fputs("Invalid token. Expected 64-char hex string.\n", stderr)
            return 2
        }

        PairingManager().removeDevice(secret: token.lowercased())
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
}

import Foundation

package final class ShellSecureDataStore: SecureDataStore {
    private let service: String
    private let keychainPath: String?
    private let keychainPassword: String?

    package init(service: String, keychainPath: String? = nil, keychainPassword: String? = nil) {
        self.service = service
        self.keychainPath = keychainPath
        self.keychainPassword = keychainPassword
    }

    package func data(for account: String) -> Data? {
        guard unlockKeychainIfNeeded() else { return nil }

        let result = runSecurity(arguments: [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ] + keychainArgument())

        guard result.terminationStatus == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .newlines)
        return Data(value.utf8)
    }

    @discardableResult
    package func setData(_ data: Data, for account: String) -> Bool {
        guard let value = String(data: data, encoding: .utf8) else { return false }
        guard unlockKeychainIfNeeded() else { return false }

        var arguments = [
            "add-generic-password",
            "-U",
            "-A",
            "-s", service,
            "-a", account,
            "-w", value
        ]
        arguments += keychainArgument()

        let result = runSecurity(arguments: arguments)

        return result.terminationStatus == 0
    }

    @discardableResult
    package func removeData(for account: String) -> Bool {
        guard unlockKeychainIfNeeded() else { return false }

        let result = runSecurity(arguments: [
            "delete-generic-password",
            "-s", service,
            "-a", account,
        ] + keychainArgument())

        return result.terminationStatus == 0 || result.stderr.contains("could not be found")
    }

    private func keychainArgument() -> [String] {
        guard let keychainPath else { return [] }
        return [keychainPath]
    }

    private func unlockKeychainIfNeeded() -> Bool {
        guard let keychainPath, let keychainPassword else { return true }
        let result = runSecurity(arguments: [
            "unlock-keychain",
            "-p", keychainPassword,
            keychainPath
        ])
        return result.terminationStatus == 0
    }

    private func runSecurity(arguments: [String]) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (1, "", error.localizedDescription)
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}

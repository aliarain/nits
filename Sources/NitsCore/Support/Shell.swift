import Foundation

/// Single-quote a string for POSIX shells. The only character a single-quoted string
/// cannot contain is a single quote, written as '\''.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public enum PrivilegedShell {
    public struct Result: Sendable {
        public let succeeded: Bool
        public let message: String?
    }

    /// Runs a shell command with the administrator authorization dialog.
    /// Returns a failure message when the user cancels or the command fails.
    public static func runWithAdministrator(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return Result(succeeded: false, message: "Could not create authorization script")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown authorization error"
            if message.localizedCaseInsensitiveContains("cancel") {
                return Result(succeeded: false, message: "Cancelled")
            }
            return Result(succeeded: false, message: message)
        }
        return Result(succeeded: true, message: nil)
    }

    public static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

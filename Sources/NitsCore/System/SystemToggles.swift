import Foundation

public enum SystemToggles {
    public static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// System-wide Dark Mode lives behind System Events, so the first call asks for
    /// Automation permission. Returns nil when the user declines.
    @discardableResult
    public static func setDarkMode(_ enabled: Bool) -> Bool? {
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(enabled ? "true" : "false")
            end tell
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NitsLog.app.error("dark mode toggle failed: \(String(describing: error[NSAppleScript.errorMessage]), privacy: .public)")
            return nil
        }
        return true
    }

    public static func toggleDarkMode() -> Bool? {
        setDarkMode(!isDarkMode)
    }
}

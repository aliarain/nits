import Foundation
import ServiceManagement

/// Launch at login through SMAppService. Works only from an app bundle; running the
/// binary directly returns false instead of throwing.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in System Settings"
        case .notRegistered: return "off"
        case .notFound: return "not found (not running from an app bundle)"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NitsLog.app.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

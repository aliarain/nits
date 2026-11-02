import Foundation

public enum NitsPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nits", isDirectory: true)
    }

    public static var configFile: URL {
        applicationSupport.appendingPathComponent("config.json")
    }

    public static var logFile: URL {
        applicationSupport.appendingPathComponent("nits.log")
    }

    public static var controlSocket: URL {
        applicationSupport.appendingPathComponent("control.sock")
    }

    public static var userCLIDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public static var privateFrameworks: URL {
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks")
    }

    @discardableResult
    public static func ensureApplicationSupport() -> Bool {
        do {
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}

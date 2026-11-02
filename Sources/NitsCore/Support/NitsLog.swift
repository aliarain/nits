import Foundation
import os

/// Unified-log category set plus a small in-memory ring the diagnostics report can read
/// without shelling out to `log show`.
public enum NitsLog {
    public static let subsystem = "app.nits"

    public static let ddc = Logger(subsystem: subsystem, category: "ddc")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let brightness = Logger(subsystem: subsystem, category: "brightness")
    public static let volume = Logger(subsystem: subsystem, category: "volume")
    public static let resolution = Logger(subsystem: subsystem, category: "resolution")
    public static let hidpi = Logger(subsystem: subsystem, category: "hidpi")
    public static let gamma = Logger(subsystem: subsystem, category: "gamma")
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let preset = Logger(subsystem: subsystem, category: "preset")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let app = Logger(subsystem: subsystem, category: "app")

    private static let ring = Ring(capacity: 800)

    public static func note(_ category: String, _ message: String) {
        ring.append("[\(category)] \(message)")
    }

    public static func recentLines(limit: Int = 200) -> [String] {
        ring.suffix(limit)
    }

    private final class Ring: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
        }

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
            lock.unlock()
        }

        func suffix(_ count: Int) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(storage.suffix(count))
        }
    }
}

import Foundation
import IOKit.pwr_mgt

/// A power assertion that keeps the display (and therefore the system) awake. Session
/// scoped: the assertion dies with the process, so quitting can never strand a Mac awake.
public final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    public init() {}

    public var isActive: Bool {
        lock.withLock { active }
    }

    @discardableResult
    public func setActive(_ on: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard on != active else { return true }

        if on {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Nits Keep Awake" as CFString,
                &id
            )
            guard result == kIOReturnSuccess else { return false }
            assertionID = id
            active = true
            return true
        }

        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        active = false
        return true
    }
}

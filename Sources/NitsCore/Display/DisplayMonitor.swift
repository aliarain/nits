import Foundation
import CoreGraphics

public extension Notification.Name {
    static let nitsDisplaysDidChange = Notification.Name("app.nits.displaysDidChange")
}

/// Wraps CG's reconfiguration callback in a debounced notification. A single hot-plug
/// often produces a storm of callbacks (begin/configure/complete for several displays),
/// so the notification fires once after the storm settles.
public final class DisplayMonitor: @unchecked Sendable {
    public private(set) var isRunning = false
    private var context: UnsafeMutableRawPointer?
    private let lock = NSLock()
    private var debounce: DispatchWorkItem?

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        let retained = Unmanaged.passRetained(self).toOpaque()
        context = retained
        CGDisplayRegisterReconfigurationCallback(nitsDisplayReconfigured, retained)
    }

    public func stop() {
        lock.lock()
        guard isRunning, let context else {
            lock.unlock()
            return
        }
        isRunning = false
        self.context = nil
        lock.unlock()

        CGDisplayRemoveReconfigurationCallback(nitsDisplayReconfigured, context)
        Unmanaged<DisplayMonitor>.fromOpaque(context).release()
    }

    fileprivate func scheduleNotification() {
        lock.lock()
        debounce?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .nitsDisplaysDidChange, object: nil)
        }
        debounce = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

private func nitsDisplayReconfigured(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // Begin is noise; a completed event carries the useful summary.
    if flags.contains(.beginConfigurationFlag) { return }
    let relevant: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .movedFlag, .setMainFlag, .setModeFlag,
        .enabledFlag, .disabledFlag, .mirrorFlag, .desktopShapeChangedFlag,
    ]
    guard !flags.isDisjoint(with: relevant) else { return }

    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.scheduleNotification()
}

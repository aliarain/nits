import Foundation
import CoreGraphics
import ColorSync

/// Owns every display's transfer table. Software dimming, contrast, color temperature,
/// per-channel gain and inversion all compose into one table, so no two features overwrite
/// each other. Adjustments are keyed by display ID in memory; persistence is the caller's
/// job (by stable UUID).
public final class GammaEngine: @unchecked Sendable {
    private struct State {
        var adjustment: GammaAdjustment
        var softwareFactor: Double
        var applied: Bool
    }

    private let lock = NSLock()
    private var states: [CGDirectDisplayID: State] = [:]
    private var observers: [NSObjectProtocol] = []

    public init() {
        observeProfileChanges()
    }

    deinit {
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    public func adjustment(for displayID: CGDirectDisplayID) -> GammaAdjustment {
        lock.withLock { states[displayID]?.adjustment ?? GammaAdjustment() }
    }

    public func softwareFactor(for displayID: CGDirectDisplayID) -> Double {
        lock.withLock { states[displayID]?.softwareFactor ?? 1.0 }
    }

    public func setAdjustment(_ adjustment: GammaAdjustment, for displayID: CGDirectDisplayID) {
        let state = lock.withLock { () -> State in
            var state = states[displayID] ?? State(
                adjustment: GammaAdjustment(),
                softwareFactor: 1,
                applied: false
            )
            state.adjustment = adjustment
            states[displayID] = state
            return state
        }
        apply(state, to: displayID)
    }

    /// 0.01...1.5. Below 1 dims; above 1 lifts the output into the panel's headroom.
    public func setSoftwareFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        let clamped = min(1.5, max(0.01, factor))
        let state = lock.withLock { () -> State in
            var state = states[displayID] ?? State(
                adjustment: GammaAdjustment(),
                softwareFactor: 1,
                applied: false
            )
            state.softwareFactor = clamped
            states[displayID] = state
            return state
        }
        apply(state, to: displayID)
    }

    public func reapply(for displayID: CGDirectDisplayID) {
        let state = lock.withLock { states[displayID] }
        guard let state else { return }
        apply(state, to: displayID)
    }

    public func reset(_ displayID: CGDirectDisplayID) {
        let wasApplied = lock.withLock { () -> Bool in
            let applied = states[displayID]?.applied ?? false
            states.removeValue(forKey: displayID)
            return applied
        }
        if wasApplied {
            writeIdentity(to: displayID)
        }
    }

    public func resetAll() {
        let ids = lock.withLock { () -> [CGDirectDisplayID] in
            let ids = Array(states.keys)
            states.removeAll()
            return ids
        }
        for id in ids { writeIdentity(to: id) }
    }

    /// ColorSync profile changes reset gamma behind our back; re-apply our table.
    private func observeProfileChanges() {
        let names = [
            kColorSyncDeviceProfilesNotification,
            kColorSyncDisplayDeviceProfilesNotification,
        ].compactMap { $0?.takeUnretainedValue() as String? }

        for name in names {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reapplyAll()
            }
            observers.append(observer)
        }
    }

    private func reapplyAll() {
        let ids = lock.withLock { Array(states.keys) }
        for id in ids { reapply(for: id) }
    }

    private func apply(_ state: State, to displayID: CGDirectDisplayID) {
        if state.adjustment.isPaused {
            writeIdentity(to: displayID)
            return
        }
        if state.adjustment.isNeutral && state.softwareFactor >= 0.999 {
            reset(displayID)
            return
        }

        let tables = GammaMath.tables(
            adjustment: state.adjustment,
            softwareFactor: state.softwareFactor
        )
        var red = tables.red.map { CGGammaValue($0) }
        var green = tables.green.map { CGGammaValue($0) }
        var blue = tables.blue.map { CGGammaValue($0) }
        CGSetDisplayTransferByTable(
            displayID,
            UInt32(GammaMath.tableSize),
            &red,
            &green,
            &blue
        )
        lock.withLock {
            var current = states[displayID] ?? state
            current.applied = true
            states[displayID] = current
        }
    }

    private func writeIdentity(to displayID: CGDirectDisplayID) {
        var red = (0..<GammaMath.tableSize).map {
            CGGammaValue($0) / CGGammaValue(GammaMath.tableSize - 1)
        }
        var green = red
        var blue = red
        CGSetDisplayTransferByTable(
            displayID,
            UInt32(GammaMath.tableSize),
            &red,
            &green,
            &blue
        )
    }
}

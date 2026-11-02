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
        /// Dimming is drawn by a black overlay window instead of the transfer table, which
        /// lets the factor reach 0 (true black) without risking an unrecoverable table.
        var overlay = false
    }

    /// Receives (display, opacity of black overlay 0...1). Installed by the app, which owns
    /// the windows; the CLI has none, so overlay dimming is applied by the running app.
    public typealias OverlaySink = @Sendable (CGDirectDisplayID, Double) -> Void
    private var overlaySink: OverlaySink?

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

    public func setOverlaySink(_ sink: OverlaySink?) {
        lock.withLock { overlaySink = sink }
    }

    public func isOverlayMode(for displayID: CGDirectDisplayID) -> Bool {
        lock.withLock { states[displayID]?.overlay ?? false }
    }

    public func setOverlayMode(_ on: Bool, for displayID: CGDirectDisplayID) {
        let (state, sink) = lock.withLock { () -> (State, OverlaySink?) in
            var state = states[displayID] ?? State(
                adjustment: GammaAdjustment(),
                softwareFactor: 1,
                applied: false
            )
            state.overlay = on
            if !on { state.softwareFactor = max(Self.minimumFactor(overlay: false), state.softwareFactor) }
            states[displayID] = state
            return (state, overlaySink)
        }
        if !on { sink?(displayID, 0) }
        apply(state, to: displayID)
    }

    // MARK: - Pure mapping

    /// Black overlay opacity for a dim factor: 1 → clear, 0 → fully black.
    public static func overlayOpacity(forFactor factor: Double) -> Double {
        min(1, max(0, 1 - factor))
    }

    /// With an overlay the table only ever lifts (>1); the overlay does the dimming.
    public static func tableFactor(forFactor factor: Double, overlay: Bool) -> Double {
        overlay ? max(1, factor) : factor
    }

    /// Without an overlay the table is never allowed to reach black.
    public static func minimumFactor(overlay: Bool) -> Double {
        overlay ? 0 : 0.01
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

    /// 0.01...1.5 (0...1.5 with overlay dimming). Below 1 dims; above 1 lifts the output
    /// into the panel's headroom.
    public func setSoftwareFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        let state = lock.withLock { () -> State in
            var state = states[displayID] ?? State(
                adjustment: GammaAdjustment(),
                softwareFactor: 1,
                applied: false
            )
            state.softwareFactor = min(1.5, max(Self.minimumFactor(overlay: state.overlay), factor))
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
        let (wasApplied, hadOverlay, sink) = lock.withLock { () -> (Bool, Bool, OverlaySink?) in
            let existing = states[displayID]
            states.removeValue(forKey: displayID)
            return (existing?.applied ?? false, existing?.overlay ?? false, overlaySink)
        }
        if hadOverlay { sink?(displayID, 0) }
        if wasApplied {
            writeIdentity(to: displayID)
        }
    }

    public func resetAll() {
        let (ids, overlays, sink) = lock.withLock { () -> ([CGDirectDisplayID], [CGDirectDisplayID], OverlaySink?) in
            let ids = Array(states.keys)
            let overlays = states.filter { $0.value.overlay }.map(\.key)
            states.removeAll()
            return (ids, overlays, overlaySink)
        }
        for id in overlays { sink?(id, 0) }
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
        if state.overlay {
            let sink = lock.withLock { overlaySink }
            sink?(displayID, Self.overlayOpacity(forFactor: state.softwareFactor))
        }
        let factor = Self.tableFactor(forFactor: state.softwareFactor, overlay: state.overlay)

        if state.adjustment.isPaused {
            writeIdentity(to: displayID)
            return
        }
        if state.adjustment.isNeutral && factor >= 0.999 {
            if state.overlay {
                // Keep the state (it carries the overlay factor); only clear the table.
                let wasApplied = lock.withLock { () -> Bool in
                    let applied = states[displayID]?.applied ?? false
                    states[displayID]?.applied = false
                    return applied
                }
                if wasApplied { writeIdentity(to: displayID) }
            } else {
                reset(displayID)
            }
            return
        }

        let tables = GammaMath.tables(
            adjustment: state.adjustment,
            softwareFactor: factor
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

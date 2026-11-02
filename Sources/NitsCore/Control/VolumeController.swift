import Foundation
import CoreGraphics

public final class VolumeController: @unchecked Sendable {
    private struct State {
        var maximum: UInt16?
        var supported: Bool?
        var lastPercent: Double?
        var preMutePercent: Double?
    }

    private let ddc: DDCEngine
    private let lock = NSLock()
    private var states: [UInt32: State] = [:]
    private var pumps: [UInt32: LatestValuePump] = [:]
    private var displayCache: [UInt32: DisplaySnapshot] = [:]
    private var forced: Set<String> = []

    public init(ddc: DDCEngine) {
        self.ddc = ddc
    }

    public func isSupported(_ display: DisplaySnapshot) -> Bool? {
        if forced.contains(display.uuid) { return true }
        return lock.withLock { states[display.id]?.supported }
    }

    public func lastPercent(for displayID: UInt32) -> Double? {
        lock.withLock { states[displayID]?.lastPercent }
    }

    public func setForced(_ on: Bool, display: DisplaySnapshot) {
        lock.withLock {
            if on { forced.insert(display.uuid) } else { forced.remove(display.uuid) }
            var state = states[display.id] ?? State()
            if on { state.supported = true }
            states[display.id] = state
        }
    }

    public func refreshVolume(for display: DisplaySnapshot) async -> Double? {
        guard !display.isBuiltin else { return nil }
        guard let value = await ddc.read(
            display: display,
            code: DDCEngine.volumeVCP,
            useCache: false
        ) else {
            return nil
        }
        let maximum = DDCVolumeMax.from(value.max)
        let percent = min(100, max(0, Double(value.current) / Double(maximum) * 100))
        lock.withLock {
            var state = states[display.id] ?? State()
            state.maximum = maximum
            state.supported = true
            state.lastPercent = percent
            states[display.id] = state
            displayCache[display.id] = display
        }
        return percent
    }

    @discardableResult
    public func setVolume(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        guard !display.isBuiltin else { return nil }
        let clamped = min(100, max(0, percent))
        lock.withLock {
            var state = states[display.id] ?? State()
            state.lastPercent = clamped
            states[display.id] = state
            displayCache[display.id] = display
        }

        if wait {
            return await writeVolume(clamped, display: display)
        }
        await pump(for: display.id).submit(clamped)
        return nil
    }

    @discardableResult
    public func toggleMute(for display: DisplaySnapshot) async -> Bool {
        let state = lock.withLock { states[display.id] ?? State() }
        let current = state.lastPercent ?? 0
        if current > 0.5 {
            lock.withLock {
                var updated = states[display.id] ?? State()
                updated.preMutePercent = current
                states[display.id] = updated
            }
            return await setVolume(0, for: display, wait: true) ?? false
        }
        let restore = state.preMutePercent ?? 50
        return await setVolume(restore, for: display, wait: true) ?? false
    }

    private func writeVolume(_ percent: Double, display: DisplaySnapshot) async -> Bool {
        let maximum = lock.withLock { states[display.id]?.maximum } ?? 100
        let raw = UInt16((percent / 100 * Double(maximum)).rounded())
        let ok = await ddc.write(display: display, code: DDCEngine.volumeVCP, value: raw)
        lock.withLock {
            var state = states[display.id] ?? State()
            state.maximum = maximum
            if ok { state.supported = true }
            state.lastPercent = percent
            states[display.id] = state
        }
        return ok
    }

    private func pump(for displayID: UInt32) -> LatestValuePump {
        lock.lock()
        if let existing = pumps[displayID] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let pump = LatestValuePump(minimumInterval: 0.05) { [weak self] value in
            guard let self else { return }
            let display = self.lock.withLock { self.displayCache[displayID] }
                ?? DisplayCatalog.snapshot(for: displayID)
            guard let display else { return }
            _ = await self.writeVolume(value, display: display)
        }

        lock.lock()
        defer { lock.unlock() }
        if let existing = pumps[displayID] { return existing }
        pumps[displayID] = pump
        return pump
    }

    public func invalidate(displayID: UInt32) {
        lock.withLock {
            states.removeValue(forKey: displayID)
            pumps.removeValue(forKey: displayID)
            displayCache.removeValue(forKey: displayID)
        }
    }
}

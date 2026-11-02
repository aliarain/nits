import Foundation
import CoreGraphics

public enum BrightnessBackend: String, Codable, Sendable {
    case native
    case ddc
    case software
    case hdrSoftware
    case unknown
}

public struct BrightnessReading: Sendable {
    public let percent: Double
    public let backend: BrightnessBackend
    public let maximum: UInt16?
}

/// Routes brightness to the best available mechanism and degrades gracefully:
///
///  1. Apple panels (built-in, Studio Display, Pro Display XDR) via DisplayServices;
///  2. external monitors over DDC;
///  3. gamma-table dimming when DDC fails, the monitor is in HDR mode, or the value is
///     below the hardware's useful floor.
///
/// DDC writes are coalesced latest-wins with a 50 ms floor, and three consecutive
/// failures latch that display to software until it reconnects. Below 15% the hardware is
/// held at 15% and gamma provides the remaining dimming, which is what keeps a cheap
/// monitor's backlight from dropping out at its minimum.
public final class BrightnessController: @unchecked Sendable {
    public static let gammaBlendThreshold = 15.0

    private struct State {
        var maximum: UInt16?
        var backend: BrightnessBackend = .unknown
        var failStreak = 0
        var lastPercent: Double?
        var hdrSoftware = false
        var extraBrightness = false
    }

    private let ddc: DDCEngine
    private let gamma: GammaEngine
    private let native: NativeBrightness

    private let lock = NSLock()
    private var states: [UInt32: State] = [:]
    private var pumps: [UInt32: LatestValuePump] = [:]
    private var displayCache: [UInt32: DisplaySnapshot] = [:]

    public init(
        ddc: DDCEngine,
        gamma: GammaEngine,
        native: NativeBrightness = .shared
    ) {
        self.ddc = ddc
        self.gamma = gamma
        self.native = native
    }

    public func backend(for displayID: UInt32) -> BrightnessBackend {
        lock.withLock { states[displayID]?.backend ?? .unknown }
    }

    private func markBackend(_ backend: BrightnessBackend, displayID: UInt32) {
        lock.withLock {
            var state = states[displayID] ?? State()
            state.backend = backend
            states[displayID] = state
        }
    }

    public func maximum(for displayID: UInt32) -> UInt16? {
        lock.withLock { states[displayID]?.maximum }
    }

    public func lastPercent(for displayID: UInt32) -> Double? {
        lock.withLock { states[displayID]?.lastPercent }
    }

    public func setHDRSoftwareDimming(_ on: Bool, for displayID: UInt32) {
        lock.withLock {
            var state = states[displayID] ?? State()
            state.hdrSoftware = on
            states[displayID] = state
        }
        if on, let percent = lastPercent(for: displayID) {
            gamma.setSoftwareFactor(max(0, percent / 100), for: displayID)
        } else if let percent = lastPercent(for: displayID), percent >= Self.gammaBlendThreshold {
            gamma.setSoftwareFactor(1, for: displayID)
        }
    }

    public func setExtraBrightness(_ on: Bool, for displayID: UInt32) {
        lock.withLock {
            var state = states[displayID] ?? State()
            state.extraBrightness = on
            states[displayID] = state
        }
    }

    // MARK: - Set

    /// Sets brightness. `wait == true` performs the write once and returns its result
    /// (CLI); otherwise the write is coalesced and the call returns immediately (UI).
    @discardableResult
    public func setBrightness(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        let clamped = min(150, max(0, percent))
        let state = lock.withLock { states[display.id] ?? State() }
        lock.withLock {
            var updated = states[display.id] ?? State()
            updated.lastPercent = clamped
            states[display.id] = updated
            displayCache[display.id] = display
        }

        if display.hasNativeBrightness || state.backend == .native {
            return setNative(clamped, for: display)
        }

        if state.hdrSoftware || state.backend == .software {
            gamma.setSoftwareFactor(max(0, clamped / 100), for: display.id)
            markBackend(.software, displayID: display.id)
            return true
        }

        // The monitor is still being probed: show the target immediately in gamma so the
        // slider never feels dead while I2C catches up.
        if state.backend == .unknown {
            gamma.setSoftwareFactor(max(0, clamped / 100), for: display.id)
        } else {
            gamma.setSoftwareFactor(Self.gammaFactor(for: clamped), for: display.id)
        }

        if wait {
            return await performDDCWrite(percent: clamped, display: display)
        }
        await pump(for: display.id).submit(clamped)
        return nil
    }

    private func setNative(_ percent: Double, for display: DisplaySnapshot) -> Bool {
        let hardware = min(100, percent)
        let ok = native.setBrightness(hardware, for: display.id)
        if percent > 100 {
            gamma.setSoftwareFactor(min(1.5, max(1, percent / 100)), for: display.id)
        } else {
            // Native panels bottom out above black; the overlay (when enabled) closes the gap.
            let blackout = gamma.isOverlayMode(for: display.id) && percent <= 0
            gamma.setSoftwareFactor(blackout ? 0 : 1, for: display.id)
        }
        if ok {
            markBackend(.native, displayID: display.id)
        }
        return ok
    }

    private func performDDCWrite(percent: Double, display: DisplaySnapshot) async -> Bool {
        let maximum = lock.withLock { states[display.id]?.maximum } ?? 100
        let hardwarePercent = Self.hardwarePercent(for: percent)
        let raw = UInt16((hardwarePercent / 100 * Double(maximum)).rounded())
        let ok = await ddc.write(display: display, code: DDCEngine.brightnessVCP, value: raw)

        lock.withLock {
            var state = states[display.id] ?? State()
            if ok {
                state.backend = .ddc
                state.failStreak = 0
                state.maximum = maximum
            } else {
                state.failStreak += 1
                if state.failStreak >= 3 {
                    state.backend = .software
                }
            }
            states[display.id] = state
        }

        if ok {
            gamma.setSoftwareFactor(Self.gammaFactor(for: percent), for: display.id)
        } else {
            let latched = lock.withLock { states[display.id]?.backend == .software }
            gamma.setSoftwareFactor(latched ? max(0, percent / 100) : Self.gammaFactor(for: percent), for: display.id)
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
            // Never re-enumerate the display (and its 200 modes) on every slider tick.
            let display = self.lock.withLock { self.displayCache[displayID] }
                ?? DisplayCatalog.snapshot(for: displayID)
            guard let display else { return }
            _ = await self.performDDCWrite(percent: value, display: display)
        }

        lock.lock()
        if let existing = pumps[displayID] {
            lock.unlock()
            return existing
        }
        pumps[displayID] = pump
        lock.unlock()
        return pump
    }

    // MARK: - Read

    public func refreshBrightness(for display: DisplaySnapshot) async -> Double? {
        if display.hasNativeBrightness {
            if let value = native.brightness(for: display.id) {
                lock.withLock {
                    var state = states[display.id] ?? State()
                    state.backend = .native
                    state.lastPercent = value
                    states[display.id] = state
                }
                return value
            }
            return nil
        }

        let latched = lock.withLock { states[display.id]?.backend == .software }
        guard !latched else { return lastPercent(for: display.id) }

        guard let value = await ddc.read(
            display: display,
            code: DDCEngine.brightnessVCP,
            useCache: false
        ), value.max > 0 else {
            return nil
        }
        let percent = Double(value.current) / Double(value.max) * 100
        lock.withLock {
            var state = states[display.id] ?? State()
            state.maximum = value.max
            state.backend = .ddc
            state.failStreak = 0
            state.lastPercent = percent
            states[display.id] = state
            displayCache[display.id] = display
        }
        return percent
    }

    public func invalidate(displayID: UInt32) {
        lock.withLock {
            states.removeValue(forKey: displayID)
            pumps.removeValue(forKey: displayID)
            displayCache.removeValue(forKey: displayID)
        }
        gamma.reset(displayID)
    }

    // MARK: - Pure mapping

    public static func hardwarePercent(for percent: Double) -> Double {
        if percent > 100 { return 100 }
        if percent < gammaBlendThreshold { return gammaBlendThreshold }
        return percent
    }

    public static func gammaFactor(for percent: Double) -> Double {
        if percent > 100 { return min(1.5, percent / 100) }
        if percent < gammaBlendThreshold { return max(0, percent / gammaBlendThreshold) }
        return 1
    }
}

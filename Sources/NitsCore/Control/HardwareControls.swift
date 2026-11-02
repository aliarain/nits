import Foundation

public enum ColorChannel: String, Codable, CaseIterable, Sendable {
    case red, green, blue

    public var vcpCode: UInt8 {
        switch self {
        case .red: return DDCEngine.redGainVCP
        case .green: return DDCEngine.greenGainVCP
        case .blue: return DDCEngine.blueGainVCP
        }
    }
}

/// DDC controls that are not brightness or volume: contrast, per-channel gain, input,
/// power and mute. Each returns nil/false when the monitor does not implement the VCP.
public final class HardwareControls: @unchecked Sendable {
    private let ddc: DDCEngine
    private let lock = NSLock()
    private var contrastMax: [UInt32: UInt16] = [:]
    private var contrastPumps: [UInt32: LatestValuePump] = [:]
    private var displayCache: [UInt32: DisplaySnapshot] = [:]

    public init(ddc: DDCEngine) {
        self.ddc = ddc
    }

    // MARK: - Contrast

    public func readContrast(for display: DisplaySnapshot) async -> Double? {
        guard let value = await ddc.read(
            display: display,
            code: DDCEngine.contrastVCP,
            useCache: false
        ), value.max > 0 else { return nil }
        lock.withLock {
            contrastMax[display.id] = value.max
            displayCache[display.id] = display
        }
        return Double(value.current) / Double(value.max) * 100
    }

    @discardableResult
    public func setContrast(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        let clamped = min(100, max(0, percent))
        lock.withLock { displayCache[display.id] = display }
        if wait {
            return await writeContrast(clamped, display: display)
        }
        await contrastPump(for: display.id).submit(clamped)
        return nil
    }

    private func writeContrast(_ percent: Double, display: DisplaySnapshot) async -> Bool {
        let maximum = lock.withLock { contrastMax[display.id] } ?? 100
        let raw = UInt16((percent / 100 * Double(maximum)).rounded())
        return await ddc.write(display: display, code: DDCEngine.contrastVCP, value: raw)
    }

    private func contrastPump(for displayID: UInt32) -> LatestValuePump {
        lock.lock()
        if let existing = contrastPumps[displayID] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let pump = LatestValuePump(minimumInterval: 0.05) { [weak self] value in
            guard let self else { return }
            let display = self.lock.withLock { self.displayCache[displayID] }
                ?? DisplayCatalog.snapshot(for: displayID)
            guard let display else { return }
            _ = await self.writeContrast(value, display: display)
        }

        lock.lock()
        defer { lock.unlock() }
        if let existing = contrastPumps[displayID] { return existing }
        contrastPumps[displayID] = pump
        return pump
    }

    // MARK: - Color gain

    public func readGain(_ channel: ColorChannel, for display: DisplaySnapshot) async -> Double? {
        guard let value = await ddc.read(
            display: display,
            code: channel.vcpCode,
            useCache: false
        ), value.max > 0 else { return nil }
        return Double(value.current) / Double(value.max) * 100
    }

    @discardableResult
    public func setGain(
        _ percent: Double,
        channel: ColorChannel,
        for display: DisplaySnapshot
    ) async -> Bool {
        let clamped = min(100, max(0, percent))
        let raw = UInt16((clamped / 100 * 100).rounded())
        return await ddc.write(display: display, code: channel.vcpCode, value: raw)
    }

    // MARK: - Power and mute

    /// VCP 0xD6: 1 = on, 4 = off (standby). Monitors that ignore it return false.
    public func setPower(_ on: Bool, for display: DisplaySnapshot) async -> Bool {
        await ddc.write(
            display: display,
            code: DDCEngine.powerVCP,
            value: on ? 1 : 4
        )
    }

    /// VCP 0x8D: 0 = unmuted, 1 = muted. Where unimplemented, VolumeController's
    /// zero-volume mute is the fallback.
    public func setMuted(_ muted: Bool, for display: DisplaySnapshot) async -> Bool {
        await ddc.write(
            display: display,
            code: DDCEngine.audioMuteVCP,
            value: muted ? 1 : 0
        )
    }

    public func invalidate(displayID: UInt32) {
        lock.withLock {
            contrastMax.removeValue(forKey: displayID)
            contrastPumps.removeValue(forKey: displayID)
            displayCache.removeValue(forKey: displayID)
        }
    }
}

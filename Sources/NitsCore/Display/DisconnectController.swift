import Foundation
import CoreGraphics

public struct DisconnectedDisplay: Codable, Identifiable, Hashable, Sendable {
    public var uuid: String
    public var displayID: UInt32
    public var name: String
    public var isBuiltin: Bool
    public var id: String { uuid }

    public init(uuid: String, displayID: UInt32, name: String, isBuiltin: Bool) {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
        self.isBuiltin = isBuiltin
    }
}

public enum DisconnectError: Error, CustomStringConvertible, Sendable {
    case unsupported
    case wouldLeaveNoActiveDisplay
    case configurationFailed(String)
    case timedOut
    case displayNotFound

    public var description: String {
        switch self {
        case .unsupported:
            return "Physical disconnect requires Apple Silicon and macOS 13 or later."
        case .wouldLeaveNoActiveDisplay:
            return "Refusing: this would leave no active display."
        case .configurationFailed(let reason):
            return "Display configuration failed: \(reason)"
        case .timedOut:
            return "Display configuration timed out (it may still land)."
        case .displayNotFound:
            return "Display is not attached."
        }
    }
}

/// Turns a physical display off and back on through SkyLight's enabled bit. This is the
/// same shape as BetterDisplay's Disconnect. Two safety rules matter more than the feature:
/// never leave zero active displays, and never run the WindowServer transaction while a
/// DDC read is in flight (WindowServer waits behind it and the whole Mac freezes).
public final class DisconnectController: @unchecked Sendable {
    private let ddc: DDCEngine
    private let lock = NSLock()
    private var records: [String: DisconnectedDisplay] = [:]

    public init(ddc: DDCEngine) {
        self.ddc = ddc
    }

    public var isSupported: Bool {
        SkyLightSupport.shared.canDisconnect
    }

    public func disconnectedDisplays() -> [DisconnectedDisplay] {
        lock.withLock { records.values.sorted { $0.name < $1.name } }
    }

    public func restoreRecords(_ records: [DisconnectedDisplay]) {
        lock.withLock {
            self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.uuid, $0) })
        }
    }

    public func clearRecords() -> [DisconnectedDisplay] {
        lock.withLock {
            let all = Array(records.values)
            records.removeAll()
            return all
        }
    }

    /// Drops records for displays that are lit again (hot-plug, reboot, manual reconnect).
    public func reconcile(online: [DisplaySnapshot]) {
        let onlineUUIDs = Set(online.map(\.uuid))
        lock.withLock {
            records = records.filter { !onlineUUIDs.contains($0.key) }
        }
    }

    public func disconnect(_ display: DisplaySnapshot) async -> Result<Void, DisconnectError> {
        guard isSupported else { return .failure(.unsupported) }
        let activeCount = DisplayCatalog.activeDisplayIDs().count
        guard activeCount > 1 else { return .failure(.wouldLeaveNoActiveDisplay) }
        guard !display.isBuiltin || activeCount > 1 else {
            return .failure(.wouldLeaveNoActiveDisplay)
        }

        let record = DisconnectedDisplay(
            uuid: display.uuid,
            displayID: display.id,
            name: display.name,
            isBuiltin: display.isBuiltin
        )

        let result = await setEnabled(display.id, enabled: false, scope: .permanently)
        switch result {
        case .success:
            lock.withLock { records[display.uuid] = record }
            return .success(())
        case .failure(.timedOut):
            // The commit may still land; keep the record so the UI can offer Reconnect.
            lock.withLock { records[display.uuid] = record }
            return .failure(.timedOut)
        case .failure(let error):
            return .failure(error)
        }
    }

    public func reconnect(_ record: DisconnectedDisplay) async -> Result<Void, DisconnectError> {
        guard isSupported else { return .failure(.unsupported) }
        guard SkyLightSupport.shared.allDisplayIDs().contains(record.displayID) else {
            _ = lock.withLock { records.removeValue(forKey: record.uuid) }
            return .failure(.displayNotFound)
        }
        let result = await setEnabled(record.displayID, enabled: true, scope: .permanently)
        lock.withLock {
            if case .success = result {
                records.removeValue(forKey: record.uuid)
            }
        }
        return result
    }

    public func reconnect(uuid: String) async -> Result<Void, DisconnectError> {
        guard let record = lock.withLock({ records[uuid] }) else {
            return .failure(.displayNotFound)
        }
        return await reconnect(record)
    }

    /// Off then on, to force macOS to re-read a freshly installed HiDPI override.
    /// Refused when there is only one active display: toggling the sole framebuffer on a
    /// laptop triggers Clamshell Sleep.
    public func softReconnect(_ display: DisplaySnapshot) async -> Bool {
        guard isSupported else { return false }
        guard DisplayCatalog.activeDisplayIDs().count > 1 else {
            NitsLog.display.notice("soft reconnect refused: only one active display")
            return false
        }

        let release = await ddc.hold()
        defer { release() }

        let disabled = await setEnabled(display.id, enabled: false, scope: .forSession, holdDDC: false)
        guard case .success = disabled else { return false }

        try? await Task.sleep(nanoseconds: 800_000_000)

        for attempt in 0..<4 {
            let enabled = await setEnabled(display.id, enabled: true, scope: .forSession, holdDDC: false)
            if case .success = enabled {
                NitsLog.display.notice("soft reconnect display \(display.id, privacy: .public): back online")
                return true
            }
            NitsLog.display.error("soft reconnect enable attempt \(attempt + 1, privacy: .public) failed")
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }

    // MARK: - Internals

    private func setEnabled(
        _ displayID: CGDirectDisplayID,
        enabled: Bool,
        scope: CGConfigureOption,
        holdDDC: Bool = true
    ) async -> Result<Void, DisconnectError> {
        let release = holdDDC ? await ddc.hold() : nil
        defer { release?() }

        let result: Result<Void, DisconnectError> = await withTimeout(
            seconds: 10,
            fallback: .failure(.timedOut)
        ) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                return .failure(.configurationFailed("begin"))
            }
            guard let skyLightResult = SkyLightSupport.shared.configureEnabled(config, displayID, enabled) else {
                CGCancelDisplayConfiguration(config)
                return .failure(.unsupported)
            }
            guard skyLightResult == .success else {
                CGCancelDisplayConfiguration(config)
                return .failure(.configurationFailed("enable=\(enabled) CGError \(skyLightResult.rawValue)"))
            }
            guard CGCompleteDisplayConfiguration(config, scope) == .success else {
                return .failure(.configurationFailed("complete"))
            }
            return .success(())
        }

        // A timed-out commit cannot be cancelled and is not proof of failure. Verify by
        // enumeration; this is the only trustworthy answer.
        if case .success = result {
            let landed = await waitForState(displayID, enabled: enabled)
            if !landed {
                NitsLog.display.notice("display \(displayID, privacy: .public): \(enabled ? "enable" : "disable") committed but not yet enumerated")
            }
        }
        return result
    }

    private func waitForState(_ displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
        for _ in 0..<20 {
            let isActive = DisplayCatalog.activeDisplayIDs().contains(displayID)
            if isActive == enabled { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

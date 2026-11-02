import Foundation
import CoreGraphics
import ColorSync

/// Reads, applies and restores display modes. All WindowServer IPC runs off the caller's
/// thread with a hard timeout, because a blocked CG transaction can otherwise wedge the
/// whole app (and in pathological cases the display server).
public final class ResolutionController: @unchecked Sendable {
    private struct SavedMode: Equatable {
        let width: Int
        let height: Int
        let refresh: Double
        let hiDPI: Bool
    }

    private let lock = NSLock()
    private var sleepSnapshot: [String: SavedMode]?

    public init() {}

    // MARK: - Query

    public func modes(for displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
        DisplayModeQuery.modes(for: displayID)
    }

    public func currentMode(for displayID: CGDirectDisplayID) -> DisplayModeInfo? {
        DisplayModeQuery.currentMode(for: displayID)
    }

    // MARK: - Apply

    public func apply(_ mode: DisplayModeInfo, to displayID: CGDirectDisplayID) async -> Bool {
        PresetNotifications.postManualChange()
        let target = resolvedTarget(for: displayID)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary

        let rawModes = CGDisplayCopyAllDisplayModes(target, options) as? [CGDisplayMode] ?? []
        let exact = rawModes.first { $0.ioDisplayModeID == mode.id }
        let matched = exact ?? rawModes.first {
            $0.width == mode.width &&
            $0.height == mode.height &&
            ($0.pixelWidth > $0.width) == mode.isHiDPI
        }

        guard let cgMode = matched else {
            return await cgsFallback(modeID: mode.id, displayID: target)
        }

        let modeID = cgMode.ioDisplayModeID
        let committed = await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            guard CGConfigureDisplayWithDisplayMode(config, target, cgMode, nil) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .forSession) == .success
        }

        if committed { return true }
        return await cgsFallback(modeID: modeID, displayID: target)
    }

    public func setResolution(
        width: Int,
        height: Int,
        refresh: Double? = nil,
        hiDPI: Bool? = nil,
        for displayID: CGDirectDisplayID
    ) async -> Bool {
        let all = DisplayModeQuery.modes(for: displayID)
        guard let mode = DisplayModeInfo.bestMatch(
            width: width,
            height: height,
            refresh: refresh,
            hiDPI: hiDPI,
            in: all
        ) else { return false }
        return await apply(mode, to: displayID)
    }

    public func toggleHiDPI(for displayID: CGDirectDisplayID) async -> Bool {
        let all = DisplayModeQuery.modes(for: displayID)
        guard let current = DisplayModeQuery.currentMode(for: displayID),
              let twin = DisplayModeInfo.hiDPITwin(of: current, in: all)
        else { return false }
        return await apply(twin, to: displayID)
    }

    public func rotate(_ displayID: CGDirectDisplayID, degrees: Int) async -> Bool {
        guard [0, 90, 180, 270].contains(degrees) else { return false }
        guard let result = SkyLightSupport.shared.setRotation(displayID, degrees: degrees) else {
            return false
        }
        if result == .success {
            NitsLog.display.notice("display \(displayID, privacy: .public): rotation set to \(degrees, privacy: .public)")
            return true
        }
        return false
    }

    // MARK: - Sleep / wake

    public func snapshotModesForSleep() {
        var snapshot: [String: SavedMode] = [:]
        for id in DisplayCatalog.onlineDisplayIDs() {
            guard let uuid = DisplayCatalog.uuid(for: id),
                  let mode = CGDisplayCopyDisplayMode(id) else { continue }
            snapshot[uuid] = SavedMode(
                width: mode.width,
                height: mode.height,
                refresh: mode.refreshRate,
                hiDPI: mode.pixelWidth > mode.width
            )
        }
        lock.withLock { sleepSnapshot = snapshot }
        NitsLog.display.notice("screens asleep: remembered \(snapshot.count, privacy: .public) mode(s)")
    }

    /// If macOS brought a display back at a different mode, restore the pre-sleep one.
    /// Matched by attributes, never by the volatile mode ID.
    public func restoreModesAfterWakeIfNeeded() async {
        let snapshot = lock.withLock { sleepSnapshot }
        guard let snapshot else { return }
        let onlineIDs = DisplayCatalog.onlineDisplayIDs()
        let online = Set(onlineIDs.compactMap { DisplayCatalog.uuid(for: $0) })
        guard online == Set(snapshot.keys) else { return }

        for id in onlineIDs {
            guard let uuid = DisplayCatalog.uuid(for: id),
                  let saved = snapshot[uuid],
                  let current = CGDisplayCopyDisplayMode(id) else { continue }
            let alreadyRight = current.width == saved.width &&
                current.height == saved.height &&
                (current.pixelWidth > current.width) == saved.hiDPI &&
                DisplayModeInfo.refreshMatches(current.refreshRate, saved.refresh)
            if alreadyRight { continue }

            let modes = DisplayModeQuery.modes(for: id)
            guard let mode = DisplayModeInfo.bestMatch(
                width: saved.width,
                height: saved.height,
                refresh: saved.refresh,
                hiDPI: saved.hiDPI,
                in: modes
            ) else { continue }
            NitsLog.display.notice("display \(id, privacy: .public): restoring pre-sleep mode \(saved.width, privacy: .public)×\(saved.height, privacy: .public)")
            _ = await apply(mode, to: id)
        }
        lock.withLock { sleepSnapshot = nil }
    }

    // MARK: - Internals

    private func resolvedTarget(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
        let source = CGDisplayMirrorsDisplay(displayID)
        guard source != kCGNullDirectDisplay else { return displayID }
        return source
    }

    /// Applies a hidden/CGS-only mode by its raw mode number. The first argument must be a
    /// real Begin/Complete token; passing a connection ID segfaults on macOS 26+.
    private func cgsFallback(modeID: Int32, displayID: CGDirectDisplayID) async -> Bool {
        guard SkyLightSupport.shared.canConfigureHiddenModes else { return false }
        let committed = await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            guard SkyLightSupport.shared.configureMode(config, displayID, mode: modeID) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .forSession) == .success
        }
        guard committed else { return false }

        // The commit propagates asynchronously; poll briefly for confirmation.
        for _ in 0..<20 {
            if CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == modeID { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}

/// Posted whenever the user changes something a preset could have set. Preset auto-apply
/// rules use it to avoid fighting manual adjustments.
public enum PresetNotifications {
    public static let manualChange = Notification.Name("app.nits.manualChange")

    public static func postManualChange() {
        NotificationCenter.default.post(name: manualChange, object: nil)
    }
}

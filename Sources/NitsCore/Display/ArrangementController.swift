import Foundation
import CoreGraphics

public struct ArrangementPosition: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Display origins, main-display switching and mirroring through the public CG
/// configuration API. Every transaction is bounded by a timeout wrapper.
public final class ArrangementController: @unchecked Sendable {
    public init() {}

    public func positions() -> [String: ArrangementPosition] {
        var result: [String: ArrangementPosition] = [:]
        for snapshot in DisplayCatalog.snapshots() {
            if let uuid = DisplayCatalog.uuid(for: snapshot.id) {
                result[uuid] = ArrangementPosition(x: snapshot.bounds.x, y: snapshot.bounds.y)
            }
        }
        return result
    }

    @discardableResult
    public func setMain(_ displayID: CGDirectDisplayID) async -> Bool {
        let displays = DisplayCatalog.snapshots()
        guard let target = displays.first(where: { $0.id == displayID }) else { return false }
        let dx = target.bounds.x
        let dy = target.bounds.y
        guard dx != 0 || dy != 0 else { return true }

        return await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            for display in displays {
                let origin = CGPoint(x: display.bounds.x - dx, y: display.bounds.y - dy)
                guard CGConfigureDisplayOrigin(config, display.id, Int32(origin.x), Int32(origin.y)) == .success else {
                    CGCancelDisplayConfiguration(config)
                    return false
                }
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    /// Applies several origins in one transaction, which is how presets restore a layout
    /// without visible intermediate arrangements.
    @discardableResult
    public func setPositions(_ positions: [CGDirectDisplayID: ArrangementPosition]) async -> Bool {
        guard !positions.isEmpty else { return true }
        return await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            for (displayID, position) in positions {
                guard CGConfigureDisplayOrigin(
                    config,
                    displayID,
                    Int32(position.x.rounded()),
                    Int32(position.y.rounded())
                ) == .success else {
                    CGCancelDisplayConfiguration(config)
                    return false
                }
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    @discardableResult
    public func setPosition(
        _ position: ArrangementPosition,
        for displayID: CGDirectDisplayID
    ) async -> Bool {
        await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            guard CGConfigureDisplayOrigin(
                config,
                displayID,
                Int32(position.x.rounded()),
                Int32(position.y.rounded())
            ) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    @discardableResult
    public func mirror(_ displayID: CGDirectDisplayID, onto sourceID: CGDirectDisplayID) async -> Bool {
        await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            guard CGConfigureDisplayMirrorOfDisplay(config, displayID, sourceID) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    @discardableResult
    public func unmirror(_ displayID: CGDirectDisplayID) async -> Bool {
        await withTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
            guard CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    public func mirrorSource(of displayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let source = CGDisplayMirrorsDisplay(displayID)
        return source == kCGNullDirectDisplay ? nil : source
    }
}

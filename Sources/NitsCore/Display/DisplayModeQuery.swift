import Foundation
import CoreGraphics

public enum DisplayModeQuery {
    public static func modes(for displayID: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }
        var seen = Set<String>()
        var result: [DisplayModeInfo] = []
        for mode in raw {
            let info = DisplayModeInfo(cgMode: mode)
            guard info.width > 0, info.height > 0 else { continue }
            let key = "\(info.width)x\(info.height)@\(String(format: "%.3f", info.refreshRate))-\(info.isHiDPI)"
            guard seen.insert(key).inserted else { continue }
            result.append(info)
        }
        return result.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            return $0.refreshRate > $1.refreshRate
        }
    }

    public static func currentMode(for displayID: CGDirectDisplayID) -> DisplayModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayModeInfo(cgMode: mode)
    }

    /// The largest non-HiDPI logical size, which is the panel's native mode for
    /// override/preset purposes.
    public static func nativeLogicalSize(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let modes = modes(for: displayID).filter { !$0.isHiDPI }
        guard let native = modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return nil
        }
        return (native.width, native.height)
    }
}

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A resolution mode as CoreGraphics sees it. `ioDisplayModeID` is not stable across
/// reconnects and mode-list rebuilds, so persisted presets match by attributes.
public struct DisplayModeInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: Int32
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var isHiDPI: Bool
    public var isUsable: Bool

    public init(
        id: Int32,
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        isHiDPI: Bool,
        isUsable: Bool
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.isUsable = isUsable
    }

    public var label: String {
        let refresh = refreshRate > 0 ? String(format: " @ %.2f Hz", refreshRate) : ""
        return "\(width)×\(height)\(isHiDPI ? " HiDPI" : "")\(refresh)"
    }

    public var aspectLabel: String {
        let divisor = greatestCommonDivisor(width, height)
        guard divisor > 0 else { return "" }
        return "\(width / divisor):\(height / divisor)"
    }

    public var refreshLabel: String {
        guard refreshRate > 0 else { return "Default" }
        return String(format: "%.2f Hz", refreshRate)
    }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return x
    }
}

public extension DisplayModeInfo {
    static func refreshMatches(_ a: Double, _ b: Double) -> Bool {
        if a == 0 || b == 0 { return true }
        return abs(a - b) < 1.0
    }

    /// The same logical size with the opposite scaling, preferring the current refresh
    /// rate, then the highest refresh. This is the HiDPI toggle.
    static func hiDPITwin(of current: DisplayModeInfo, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        let twins = modes.filter {
            $0.width == current.width &&
            $0.height == current.height &&
            $0.isHiDPI != current.isHiDPI &&
            $0.isUsable
        }
        return twins.first { refreshMatches($0.refreshRate, current.refreshRate) }
            ?? twins.max { $0.refreshRate < $1.refreshRate }
    }

    /// The "looks like" ladder behind the resolution slider: usable modes with the same
    /// scaling and aspect ratio as `current`, one per logical size (keeping the refresh
    /// closest to the current one), ordered from largest text to most space.
    static func scaleLadder(from modes: [DisplayModeInfo], current: DisplayModeInfo) -> [DisplayModeInfo] {
        let aspect = Double(current.width) / Double(max(current.height, 1))
        let sameKind = modes.filter {
            $0.isUsable &&
            $0.isHiDPI == current.isHiDPI &&
            abs(Double($0.width) / Double(max($0.height, 1)) - aspect) < 0.02
        }
        var best: [Int: DisplayModeInfo] = [:]
        for mode in sameKind {
            guard let existing = best[mode.width] else {
                best[mode.width] = mode
                continue
            }
            let modeMatches = refreshMatches(mode.refreshRate, current.refreshRate)
            let existingMatches = refreshMatches(existing.refreshRate, current.refreshRate)
            if modeMatches != existingMatches {
                if modeMatches { best[mode.width] = mode }
            } else if mode.refreshRate > existing.refreshRate {
                best[mode.width] = mode
            }
        }
        return best.values.sorted { $0.width < $1.width }
    }

    /// Index of `current` on a ladder built from the same modes, or nil when it is absent.
    static func ladderIndex(of current: DisplayModeInfo, in ladder: [DisplayModeInfo]) -> Int? {
        ladder.firstIndex { $0.width == current.width && $0.height == current.height }
    }

    /// Match a saved resolution by attributes rather than by the volatile mode ID.
    static func bestMatch(
        width: Int,
        height: Int,
        refresh: Double?,
        hiDPI: Bool?,
        in modes: [DisplayModeInfo]
    ) -> DisplayModeInfo? {
        var candidates = modes.filter { $0.width == width && $0.height == height && $0.isUsable }
        if let hiDPI {
            let exact = candidates.filter { $0.isHiDPI == hiDPI }
            if !exact.isEmpty { candidates = exact }
        }
        if let refresh, let exact = candidates.first(where: { refreshMatches($0.refreshRate, refresh) }) {
            return exact
        }
        if !candidates.isEmpty {
            return candidates.max { $0.refreshRate < $1.refreshRate }
        }

        // Allow portrait/landscape equivalence when the panel is rotated.
        var swapped = modes.filter { $0.width == height && $0.height == width && $0.isUsable }
        if let hiDPI {
            let exact = swapped.filter { $0.isHiDPI == hiDPI }
            if !exact.isEmpty { swapped = exact }
        }
        if let refresh, let exact = swapped.first(where: { refreshMatches($0.refreshRate, refresh) }) {
            return exact
        }
        return swapped.max { $0.refreshRate < $1.refreshRate }
    }
}

#if canImport(CoreGraphics)
public extension DisplayModeInfo {
    init(cgMode: CGDisplayMode) {
        self.init(
            id: cgMode.ioDisplayModeID,
            width: cgMode.width,
            height: cgMode.height,
            pixelWidth: cgMode.pixelWidth,
            pixelHeight: cgMode.pixelHeight,
            refreshRate: cgMode.refreshRate,
            isHiDPI: cgMode.pixelWidth > cgMode.width,
            isUsable: cgMode.isUsableForDesktopGUI()
        )
    }
}
#endif

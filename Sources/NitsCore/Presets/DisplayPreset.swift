import Foundation

public struct ModeSpec: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double?
    public var hiDPI: Bool

    public init(width: Int, height: Int, refreshRate: Double?, hiDPI: Bool) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }

    public init(mode: DisplayModeInfo) {
        self.init(
            width: mode.width,
            height: mode.height,
            refreshRate: mode.refreshRate,
            hiDPI: mode.isHiDPI
        )
    }

    public var label: String {
        let refresh = refreshRate.map { String(format: " @ %.0f Hz", $0) } ?? ""
        return "\(width)×\(height)\(hiDPI ? " HiDPI" : "")\(refresh)"
    }
}

/// One display's slice of a preset. `nil` means "this preset does not touch it", so old
/// presets remain valid as new fields are added.
public struct DisplayPresetEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var displayUUID: String
    public var mode: ModeSpec?
    public var brightness: Double?
    public var volume: Double?
    public var contrast: Double?
    public var input: UInt16?
    public var gamma: GammaAdjustment?
    public var position: ArrangementPosition?
    public var connected: Bool?
    public var hdrSoftware: Bool?

    public init(
        id: UUID = UUID(),
        displayUUID: String,
        mode: ModeSpec? = nil,
        brightness: Double? = nil,
        volume: Double? = nil,
        contrast: Double? = nil,
        input: UInt16? = nil,
        gamma: GammaAdjustment? = nil,
        position: ArrangementPosition? = nil,
        connected: Bool? = nil,
        hdrSoftware: Bool? = nil
    ) {
        self.id = id
        self.displayUUID = displayUUID
        self.mode = mode
        self.brightness = brightness
        self.volume = volume
        self.contrast = contrast
        self.input = input
        self.gamma = gamma
        self.position = position
        self.connected = connected
        self.hdrSoftware = hdrSoftware
    }
}

public struct DisplayPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var entries: [DisplayPresetEntry]
    public var hotkey: HotkeyBinding?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "display",
        entries: [DisplayPresetEntry],
        hotkey: HotkeyBinding? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.entries = entries
        self.hotkey = hotkey
        self.createdAt = createdAt
    }
}

public struct PresetApplyResult: Sendable {
    public var applied: [String] = []
    public var skipped: [String] = []
    public var errors: [String] = []

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if !applied.isEmpty { parts.append("applied to \(applied.count) display(s)") }
        if !skipped.isEmpty { parts.append("skipped \(skipped.count)") }
        if !errors.isEmpty { parts.append(errors.joined(separator: "; ")) }
        return parts.joined(separator: ", ")
    }
}

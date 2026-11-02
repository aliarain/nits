import Foundation

public struct DisplaySettings: Codable, Hashable, Sendable {
    public var gamma: GammaAdjustment?
    public var softwareFactor: Double?
    public var brightness: Double?
    public var volume: Double?
    public var contrast: Double?
    public var hdrSoftwareDimming: Bool?
    public var extraBrightness: Bool?
    public var forcedVolume: Bool?
    public var lastInput: UInt16?
    public var customName: String?
    public var defaultMode: ModeSpec?
    /// Keyed by DisplayEventAction.Event.rawValue.
    public var eventActions: [String: DisplayEventAction]?

    public init() {}
}

public struct DisplayEventAction: Codable, Hashable, Sendable {
    public enum Event: String, Codable, CaseIterable, Sendable {
        case connect, disconnect, sleep, wake

        public var label: String {
            switch self {
            case .connect: return "Connect"
            case .disconnect: return "Disconnect"
            case .sleep: return "Sleep"
            case .wake: return "Wake"
            }
        }
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case preset, url, script

        public var label: String {
            switch self {
            case .preset: return "Preset"
            case .url: return "URL"
            case .script: return "Script"
            }
        }
    }

    public var event: Event
    public var kind: Kind
    public var value: String

    public init(event: Event, kind: Kind, value: String) {
        self.event = event
        self.kind = kind
        self.value = value
    }
}

public struct DisplayGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var displayUUIDs: [String]
    public var syncBrightness: Bool
    public var syncVolume: Bool
    public var syncImage: Bool
    public var syncInput: Bool
    public var syncResolution: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        displayUUIDs: [String] = [],
        syncBrightness: Bool = true,
        syncVolume: Bool = false,
        syncImage: Bool = false,
        syncInput: Bool = false,
        syncResolution: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayUUIDs = displayUUIDs
        self.syncBrightness = syncBrightness
        self.syncVolume = syncVolume
        self.syncImage = syncImage
        self.syncInput = syncInput
        self.syncResolution = syncResolution
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    public var showOSD: Bool = true
    public var osdDuration: Double = 1.2
    public var brightnessStep: Double = 6.25
    public var volumeStep: Double = 6.25
    public var syncBrightness: Bool = false
    public var syncGroup: [String] = []
    public var autoInstallHiDPI: Bool = false
    public var restoreBrightnessOnConnect: Bool = true
    public var mediaKeysEnabled: Bool = false
    public var launchAtLogin: Bool = false
    public var keepAwake: Bool = false
    public var hotkeys: [String: HotkeyBinding] = [:]

    public init() {}
}

public struct NitsConfig: Codable, Sendable {
    public var version: Int = 1
    public var presets: [DisplayPreset] = []
    public var displaySettings: [String: DisplaySettings] = [:]
    public var disconnected: [DisconnectedDisplay] = []
    /// Optional so configs written before these features still decode.
    public var virtualDisplays: [VirtualDisplayConfig]? = nil
    public var groups: [DisplayGroup]? = nil
    public var general: GeneralSettings = GeneralSettings()
    /// Any CLI/app command that changes display state bumps this. Concurrent processes
    /// use it to notice the other's writes before overwriting them.
    public var revision: Int = 0

    public init() {}
}

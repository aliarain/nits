import Foundation

/// A global shortcut as Carbon stores it. `keyCode` is a virtual key code and
/// `modifiers` is a Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
public struct HotkeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Human-readable label captured when recorded ("⌃⌥B"). Purely for display.
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

public enum HotkeyAction: Hashable, Sendable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case cycleInput
    case toggleHiDPI
    case toggleMute
    case preset(UUID)
}

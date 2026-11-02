import AppKit
import NitsCore

enum KeyboardShortcuts {
    // Carbon modifier masks. Kept as literals so this file needs no Carbon import.
    static let cmdKey: UInt32 = 256
    static let shiftKey: UInt32 = 512
    static let optionKey: UInt32 = 2048
    static let controlKey: UInt32 = 4096

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.command) { result |= cmdKey }
        return result
    }

    static func label(for binding: HotkeyBinding?) -> String {
        binding?.label ?? "Record"
    }

    static func label(for event: NSEvent) -> String {
        var text = ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += keyName(for: event.keyCode, characters: event.charactersIgnoringModifiers)
        return text
    }

    static func keyName(for keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 71: return "⌧"
        case 76: return "⌤"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let text = characters?.uppercased() ?? "?"
            return text.isEmpty ? "?" : text
        }
    }
}

import Foundation

/// Some monitor firmware fills the high byte of the VCP 0x62 max (a Dell reporting
/// 0xFF64 for 0...100). Scale by the low byte, which is what ddcutil reads.
public enum DDCVolumeMax {
    public static func from(_ reported: UInt16) -> UInt16 {
        let low = reported & 0xFF
        return low == 0 ? 100 : low
    }
}

public struct InputOption: Codable, Hashable, Sendable, Identifiable {
    public var value: UInt16
    public var name: String
    public var id: UInt16 { value }

    public init(value: UInt16, name: String) {
        self.value = value
        self.name = name
    }
}

/// DDC input select (VCP 0x60). MCCS names the common connectors; monitors can list
/// their own set in the capabilities string.
public enum InputSource {
    public static let vcp: UInt8 = 0x60
    public static let standard: [UInt16] = [0x0F, 0x10, 0x11, 0x12, 0x1B]

    private static let names: [UInt16: String] = [
        0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2",
        0x0F: "DisplayPort 1", 0x10: "DisplayPort 2",
        0x11: "HDMI 1", 0x12: "HDMI 2", 0x1B: "USB-C",
    ]

    public static func name(for value: UInt16) -> String? {
        names[value & 0xFF]
    }

    /// Some monitors set flags in the high byte; the input value is the low byte.
    public static func current(fromReply value: UInt16) -> UInt16 {
        value & 0xFF
    }

    public static func options(from capabilities: DDCCapabilities?) -> [InputOption] {
        let values = capabilities?.inputs ?? standard
        return values.map { value in
            InputOption(value: value, name: name(for: value) ?? String(format: "Input 0x%02X", value))
        }
    }

    /// Parse a user-typed input: "hdmi1", "dp2", "usb-c", "17", "0x11".
    public static func value(from text: String) -> UInt16? {
        let compact = text.lowercased().filter { !" -_".contains($0) }
        for (value, name) in names {
            let alias = name.lowercased().filter { !" -".contains($0) }
            if alias == compact { return value }
        }
        if compact == "dp1" { return 0x0F }
        if compact == "dp2" { return 0x10 }
        if compact == "usbc" { return 0x1B }
        if compact.hasPrefix("0x") {
            return UInt16(compact.dropFirst(2), radix: 16)
        }
        return UInt16(compact)
    }
}

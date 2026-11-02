import Foundation

public struct DDCValue: Equatable, Sendable {
    public let current: UInt16
    public let max: UInt16

    public init(current: UInt16, max: UInt16) {
        self.current = current
        self.max = max
    }

    public var fraction: Double {
        guard max > 0 else { return 0 }
        return Double(current) / Double(max)
    }
}

/// Pure DDC/CI framing. Every byte here is specified by MCCS/DDC-CI 1.1; keeping it
/// separate from I2C makes the fragile part (checksums, reply headers) testable.
public enum DDCPacket {
    public static let destAddress: UInt8 = 0x6E
    public static let sourceAddress: UInt8 = 0x6E
    public static let replyAddress: UInt8 = 0x6F
    public static let hostSourceAddress: UInt8 = 0x51

    /// The checksum seed for a host->display packet: destination 0x6E XOR sub-address 0x51.
    public static let hostChecksumSeed: UInt8 = 0x6E ^ 0x51
    /// The checksum seed for a display->host reply: source 0x50 XOR 0x6E... DDC uses 0x50.
    public static let replyChecksumSeed: UInt8 = 0x50

    public static func xorChecksum(seed: UInt8, bytes: [UInt8]) -> UInt8 {
        var checksum = seed
        for byte in bytes { checksum ^= byte }
        return checksum
    }

    /// Get VCP Feature request payload (after the 0x51 sub-address).
    /// [0x82, 0x01, code, checksum]
    public static func getVCP(_ code: UInt8) -> [UInt8] {
        let payload: [UInt8] = [0x82, 0x01, code]
        return payload + [xorChecksum(seed: hostChecksumSeed, bytes: payload)]
    }

    /// Set VCP Feature request payload.
    /// [0x84, 0x03, code, valueHigh, valueLow, checksum]
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        let payload: [UInt8] = [0x84, 0x03, code, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return payload + [xorChecksum(seed: hostChecksumSeed, bytes: payload)]
    }

    /// Capabilities Request: [0x83, 0xF3, offsetHigh, offsetLow, checksum].
    public static func capabilitiesRequest(offset: Int) -> [UInt8] {
        let payload: [UInt8] = [
            0x83, 0xF3,
            UInt8((offset >> 8) & 0xFF),
            UInt8(offset & 0xFF),
        ]
        return payload + [xorChecksum(seed: hostChecksumSeed, bytes: payload)]
    }

    /// Validates a Get VCP Feature reply and extracts (current, max).
    ///
    /// Reply layout: [source 0x6E, len, 0x02, result, vcp echo, type, maxHi, maxLo, curHi, curLo, checksum].
    /// An I2C ACK is not proof of a real reply: monitors can return stale EDID bytes, a
    /// DDC NULL frame, or garbage with a plausible header. Require the header AND checksum.
    public static func parseGetReply(
        _ reply: [UInt8],
        expecting code: UInt8,
        allowZeroMax: Bool = false
    ) -> DDCValue? {
        guard reply.count >= 11 else { return nil }
        guard reply[0] == sourceAddress,
              reply[2] == 0x02,
              reply[3] == 0x00,
              reply[4] == code
        else { return nil }
        guard xorChecksum(seed: replyChecksumSeed, bytes: Array(reply[0...9])) == reply[10] else {
            return nil
        }
        let maxValue = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maxValue > 0 || allowZeroMax else { return nil }
        return DDCValue(current: current, max: maxValue)
    }

    /// Set-reply detection is not part of normal operation, but the doctor uses it to
    /// distinguish "write ignored" from "write rejected".
    public static func isSuccessReply(_ reply: [UInt8], expecting code: UInt8) -> Bool {
        guard reply.count >= 3, reply[0] == sourceAddress, reply[2] == 0x02 else { return false }
        return reply.count < 5 || reply[4] == code
    }
}

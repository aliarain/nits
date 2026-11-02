import Foundation

/// The capabilities string a monitor returns for request 0xF3: an MCCS capability
/// report wrapped in parentheses, e.g. `(prot(monitor)type(lcd)mccs_ver(2.1)vcp(10 12 ...))`.
public struct DDCCapabilities: Codable, Hashable, Sendable {
    public var raw: String
    public var vcpCodes: [UInt8]
    public var inputs: [UInt16]?
    public var mccsVersion: String?

    public init(raw: String, vcpCodes: [UInt8], inputs: [UInt16]?, mccsVersion: String?) {
        self.raw = raw
        self.vcpCodes = vcpCodes
        self.inputs = inputs
        self.mccsVersion = mccsVersion
    }

    public static let empty = DDCCapabilities(raw: "", vcpCodes: [], inputs: nil, mccsVersion: nil)

    public func supports(_ code: UInt8) -> Bool {
        vcpCodes.contains(code)
    }

    public static func parse(_ raw: String) -> DDCCapabilities {
        let upper = raw.uppercased()
        let vcpCodes = parseVCPList(upper)
        let inputs = parseInputs(upper)
        let version = parseVersion(upper)
        return DDCCapabilities(raw: raw, vcpCodes: vcpCodes, inputs: inputs, mccsVersion: version)
    }

    // MARK: - Parsing

    private static func parseVCPList(_ text: String) -> [UInt8] {
        guard let body = contents(of: "VCP", in: text) else { return [] }
        var values: [UInt8] = []
        var token = ""
        func flush() {
            if let value = UInt8(token, radix: 16), !values.contains(value) {
                values.append(value)
            }
            token = ""
        }
        for character in body {
            if character.isHexDigit {
                token.append(character)
                if token.count == 2 {
                    flush()
                }
            } else {
                flush()
            }
        }
        flush()
        return values
    }

    private static func parseInputs(_ text: String) -> [UInt16]? {
        guard let body = contents(of: "60", in: text, requireTokenBoundary: true) else { return nil }
        var values: [UInt16] = []
        var token = ""
        func flush() {
            if let value = UInt16(token, radix: 16), value != 0, !values.contains(value) {
                values.append(value)
            }
            token = ""
        }
        for character in body {
            if character.isHexDigit {
                token.append(character)
            } else {
                flush()
            }
        }
        flush()
        return values.isEmpty ? nil : values
    }

    private static func parseVersion(_ text: String) -> String? {
        guard let body = contents(of: "MCCS_VER", in: text) else { return nil }
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Returns the text inside the parentheses that follow `name(`. For "60" the match
    /// must start at a token boundary so `160(01)` is not mistaken for input select.
    private static func contents(
        of name: String,
        in text: String,
        requireTokenBoundary: Bool = false
    ) -> String? {
        let characters = Array(text)
        let marker = Array(name + "(")
        guard characters.count >= marker.count else { return nil }

        for start in 0...(characters.count - marker.count) {
            guard Array(characters[start..<start + marker.count]) == marker else { continue }
            if requireTokenBoundary, start > 0, characters[start - 1].isHexDigit {
                continue
            }
            var index = start + marker.count
            var depth = 1
            var body = ""
            while index < characters.count, depth > 0 {
                let character = characters[index]
                index += 1
                if character == "(" {
                    depth += 1
                    if depth > 1 { body.append(character) }
                } else if character == ")" {
                    depth -= 1
                    if depth > 0 { body.append(character) }
                } else if depth > 0 {
                    body.append(character)
                }
            }
            return depth == 0 ? body : nil
        }
        return nil
    }
}

/// Chunked capabilities transport framing (DDC/CI 1.1).
public enum DDCCapabilitiesCodec {
    /// Header, offset (2), up to 32 data bytes and checksum.
    public static let replyLength = 38

    /// One chunk's data, empty at the end of the string, nil for a framing error.
    public static func data(fromReply reply: [UInt8], offset: Int) -> [UInt8]? {
        guard reply.count >= 6, reply[0] == DDCPacket.sourceAddress, reply[2] == 0xE3 else {
            return nil
        }
        let length = Int(reply[1] & 0x7F)
        guard length >= 3, length <= 35, reply.count > length + 2 else { return nil }
        guard (Int(reply[3]) << 8 | Int(reply[4])) == offset else { return nil }
        let checksum = reply[0..<(length + 2)].reduce(DDCPacket.replyChecksumSeed, ^)
        guard checksum == reply[length + 2] else { return nil }
        return Array(reply[5..<(length + 2)])
    }
}

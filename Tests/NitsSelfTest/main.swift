import Foundation
import NitsCore

harness.suite("DDC packets") {
    let set = DDCPacket.setVCP(0x10, value: 0x1234)
    harness.equal(set, [0x84, 0x03, 0x10, 0x12, 0x34, 0x84 ^ 0x03 ^ 0x10 ^ 0x12 ^ 0x34 ^ 0x3F], "Set VCP layout")
    harness.equal(set.last, DDCPacket.xorChecksum(seed: DDCPacket.hostChecksumSeed, bytes: Array(set.dropLast())), "Set VCP checksum")

    harness.equal(DDCPacket.getVCP(0x10), [0x82, 0x01, 0x10, 0x82 ^ 0x01 ^ 0x10 ^ 0x3F], "Get VCP layout")
    harness.equal(
        DDCPacket.capabilitiesRequest(offset: 0x0120),
        [0x83, 0xF3, 0x01, 0x20, 0x83 ^ 0xF3 ^ 0x01 ^ 0x20 ^ 0x3F],
        "Capabilities request layout"
    )

    func reply(code: UInt8, max: UInt16, current: UInt16, result: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [
            0x6E, 0x88, 0x02, result, code, 0x00,
            UInt8(max >> 8), UInt8(max & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        bytes.append(DDCPacket.xorChecksum(seed: 0x50, bytes: bytes))
        return bytes
    }

    harness.equal(
        DDCPacket.parseGetReply(reply(code: 0x10, max: 100, current: 42), expecting: 0x10),
        DDCValue(current: 42, max: 100),
        "Valid reply parses"
    )
    harness.nilValue(
        DDCPacket.parseGetReply(reply(code: 0x10, max: 100, current: 42), expecting: 0x12),
        "Wrong VCP echo rejected"
    )
    var corrupt = reply(code: 0x10, max: 100, current: 42)
    corrupt[10] ^= 0xFF
    harness.nilValue(DDCPacket.parseGetReply(corrupt, expecting: 0x10), "Bad checksum rejected")
    harness.nilValue(
        DDCPacket.parseGetReply(reply(code: 0x10, max: 100, current: 42, result: 1), expecting: 0x10),
        "Error result code rejected"
    )
    harness.nilValue(
        DDCPacket.parseGetReply(reply(code: 0x10, max: 0, current: 0), expecting: 0x10),
        "Zero max rejected for brightness"
    )
    harness.equal(
        DDCPacket.parseGetReply(reply(code: 0x60, max: 0, current: 0x11), expecting: 0x60, allowZeroMax: true),
        DDCValue(current: 0x11, max: 0),
        "Input select allows zero max"
    )
    harness.nilValue(
        DDCPacket.parseGetReply([0x6E, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0], expecting: 0x10),
        "DDC null frame rejected"
    )
}

harness.suite("DDC capabilities") {
    let raw = "(prot(monitor)type(lcd)cmds(01 02 03)vcp(02 04 05 10 12 14 16 18 1A 60(0F 10 11 12 1B) 62 6C 87 D6 DC)mccs_ver(2.1))"
    let caps = DDCCapabilities.parse(raw)
    harness.check(caps.supports(0x10), "brightness supported")
    harness.check(caps.supports(0x62), "volume supported")
    harness.check(!caps.supports(0x99), "unknown VCP not supported")
    harness.equal(caps.mccsVersion, "2.1", "MCCS version parsed")
    harness.equal(caps.inputs, [0x0F, 0x10, 0x11, 0x12, 0x1B], "input list parsed")

    let spaced = DDCCapabilities.parse("vcp(10 12 60(0f 10 11 12 1b))mccs_ver(2.2)")
    harness.equal(spaced.inputs, [0x0F, 0x10, 0x11, 0x12, 0x1B], "lowercase/spaced inputs parsed")
    harness.equal(spaced.mccsVersion, "2.2", "version parsed from noisy string")
    harness.nilValue(DDCCapabilities.parse("vcp(10 12 160(01 02))").inputs, "160 token is not input select")

    // Length byte is the header/offset/data count incl. the trailing checksum: 6 here
    // for three data bytes (offset 2 + data 3 + checksum 1).
    var chunk: [UInt8] = [0x6E, 0x86, 0xE3, 0x00, 0x00, 0x01, 0x02, 0x03]
    chunk.append(DDCPacket.xorChecksum(seed: 0x50, bytes: chunk))
    harness.equal(DDCCapabilitiesCodec.data(fromReply: chunk, offset: 0), [0x01, 0x02, 0x03], "capabilities chunk parsed")

    var wrongOffset: [UInt8] = [0x6E, 0x86, 0xE3, 0x00, 0x10, 0x01]
    wrongOffset.append(DDCPacket.xorChecksum(seed: 0x50, bytes: wrongOffset))
    harness.nilValue(DDCCapabilitiesCodec.data(fromReply: wrongOffset, offset: 0), "wrong capabilities offset rejected")
}

harness.suite("DDC pairing") {
    let a = DisplayIdentity(vendor: 1, product: 2, serial: 3, location: "A")
    let b = DisplayIdentity(vendor: 1, product: 2, serial: 3, location: "B")
    let byLocation = DDCPairing.match(
        channels: [b, a],
        displays: [(id: 10, identity: a), (id: 20, identity: b)]
    )
    harness.equal(byLocation.byDisplayID[10], 1, "location matches first display")
    harness.equal(byLocation.byDisplayID[20], 0, "location matches second display")
    harness.check(!byLocation.ambiguous, "location matching is unambiguous")
    harness.equal(byLocation.identityMatches, 2, "both matched by identity")

    let serial = DDCPairing.match(
        channels: [DisplayIdentity(vendor: 1, product: 2, serial: 99)],
        displays: [
            (id: 10, identity: DisplayIdentity(vendor: 1, product: 2, serial: 11)),
            (id: 20, identity: DisplayIdentity(vendor: 1, product: 2, serial: 99)),
        ]
    )
    harness.equal(serial.byDisplayID, [20: 0], "serial distinguishes identical models")

    let fallback = DDCPairing.match(
        channels: [nil, nil],
        displays: [
            (id: 30, identity: DisplayIdentity(vendor: 0, product: 0, serial: 0)),
            (id: 10, identity: DisplayIdentity(vendor: 0, product: 0, serial: 0)),
        ]
    )
    harness.equal(fallback.byDisplayID[10], 0, "traversal fallback uses sorted IDs")
    harness.equal(fallback.byDisplayID[30], 1, "traversal fallback assigns second channel")
    harness.check(fallback.ambiguous, "ambiguous fallback is flagged")
}

harness.suite("Display modes and selectors") {
    func mode(_ w: Int, _ h: Int, _ refresh: Double, hidpi: Bool, id: Int32 = 1) -> DisplayModeInfo {
        DisplayModeInfo(
            id: id, width: w, height: h,
            pixelWidth: hidpi ? w * 2 : w, pixelHeight: hidpi ? h * 2 : h,
            refreshRate: refresh, isHiDPI: hidpi, isUsable: true
        )
    }

    let current = mode(1920, 1080, 60, hidpi: false)
    let twins = [
        mode(1920, 1080, 144, hidpi: true, id: 2),
        mode(1920, 1080, 60, hidpi: true, id: 3),
    ]
    harness.equal(DisplayModeInfo.hiDPITwin(of: current, in: twins)?.id, 3, "HiDPI twin keeps refresh rate")

    let refreshModes = [
        mode(2560, 1440, 60, hidpi: true, id: 1),
        mode(2560, 1440, 120, hidpi: true, id: 2),
    ]
    harness.equal(
        DisplayModeInfo.bestMatch(width: 2560, height: 1440, refresh: nil, hiDPI: true, in: refreshModes)?.id,
        2,
        "mode match falls back to highest refresh"
    )

    let ladderCurrent = mode(2560, 1440, 120, hidpi: true, id: 10)
    let ladderModes = [
        mode(1280, 720, 60, hidpi: true, id: 11),
        mode(1280, 720, 120, hidpi: true, id: 12),
        ladderCurrent,
        mode(2560, 1440, 60, hidpi: true, id: 13),
        mode(1920, 1080, 120, hidpi: true, id: 14),
        mode(1920, 1200, 120, hidpi: true, id: 15),
        mode(1920, 1080, 120, hidpi: false, id: 16),
        mode(3200, 1800, 120, hidpi: true, id: 17),
    ]
    let ladder = DisplayModeInfo.scaleLadder(from: ladderModes, current: ladderCurrent)
    harness.equal(ladder.map(\.width), [1280, 1920, 2560, 3200], "scale ladder is one rung per size, ascending")
    harness.equal(ladder.first?.id, 12, "scale ladder keeps the refresh closest to current")
    harness.equal(DisplayModeInfo.ladderIndex(of: ladderCurrent, in: ladder), 2, "ladder index locates the current size")

    let builtin = DisplaySnapshot(
        id: 1, uuid: "AAA-111", name: "Built-in Display",
        identity: DisplayIdentity(vendor: 1, product: 2, serial: 3),
        isBuiltin: true, isMain: false, isActive: true,
        bounds: DisplayBounds(x: 0, y: 0, width: 100, height: 100),
        rotation: 0, pixelWidth: 100, pixelHeight: 100,
        nativeWidth: 100, nativeHeight: 100, panelWidth: 100, panelHeight: 100,
        hasNativeBrightness: true, connection: "Built-in"
    )
    let external = DisplaySnapshot(
        id: 42, uuid: "BBB-222", name: "Studio Display",
        identity: DisplayIdentity(vendor: 4, product: 5, serial: 6),
        isBuiltin: false, isMain: true, isActive: true,
        bounds: DisplayBounds(x: 0, y: 0, width: 100, height: 100),
        rotation: 0, pixelWidth: 100, pixelHeight: 100,
        nativeWidth: 100, nativeHeight: 100, panelWidth: 100, panelHeight: 100,
        hasNativeBrightness: false, connection: "External"
    )
    let displays = [builtin, external]
    harness.equal(DisplaySelector.match(nil, in: displays)?.id, 42, "nil selector picks main")
    harness.equal(DisplaySelector.match("builtin", in: displays)?.id, 1, "builtin selector")
    harness.equal(DisplaySelector.match("42", in: displays)?.id, 42, "numeric selector")
    harness.equal(DisplaySelector.match("bbb", in: displays)?.id, 42, "UUID prefix selector")
    harness.equal(DisplaySelector.match("studio", in: displays)?.id, 42, "name selector")
    harness.equal(DisplaySelector.matchAll("all", in: displays).count, 2, "all selector")
}

runControlTests()

harness.finish()

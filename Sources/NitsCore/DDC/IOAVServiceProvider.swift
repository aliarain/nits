#if arch(arm64)
import Foundation
import CoreGraphics
import IOKit

/// The Apple Silicon DDC path: IOAVService I2C against a DCPAVServiceProxy registry node.
/// These symbols are exported by IOKit but absent from the public SDK headers, so they are
/// resolved with dlsym rather than linked.
final class IOAVSymbols: @unchecked Sendable {
    typealias CreateWithService =
        @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    typealias WriteI2C =
        @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias ReadI2C =
        @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> Int32

    static let shared = IOAVSymbols()

    let createWithService: CreateWithService?
    let writeI2C: WriteI2C?
    let readI2C: ReadI2C?

    private init() {
        let handles = Self.openHandles()
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            for handle in handles {
                if let found = dlsym(handle, name) { return found }
            }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        createWithService = symbol("IOAVServiceCreateWithService").map {
            unsafeBitCast($0, to: CreateWithService.self)
        }
        writeI2C = symbol("IOAVServiceWriteI2C").map {
            unsafeBitCast($0, to: WriteI2C.self)
        }
        readI2C = symbol("IOAVServiceReadI2C").map {
            unsafeBitCast($0, to: ReadI2C.self)
        }
    }

    private static func openHandles() -> [UnsafeMutableRawPointer] {
        let paths = [
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            "/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit",
            "/usr/lib/libIOAVService.dylib",
        ]
        return paths.compactMap { dlopen($0, RTLD_LAZY) }
    }

    var isAvailable: Bool {
        createWithService != nil && writeI2C != nil && readI2C != nil
    }
}

final class IOAVChannel: DDCChannel, @unchecked Sendable {
    private let service: UnsafeMutableRawPointer
    private let symbols: IOAVSymbols
    /// DCP uses 0x37; the MCDP29xx HDMI controller routes DDC through 0xB7.
    private let chipAddress: UInt32
    private let readDelay: TimeInterval

    init(
        service: UnsafeMutableRawPointer,
        chipAddress: UInt32 = 0x37,
        readDelay: TimeInterval = 0.04,
        symbols: IOAVSymbols = .shared
    ) {
        self.service = service
        self.chipAddress = chipAddress
        // Support can tune this for a stubborn panel: NITS_DDC_DELAY=0.03 (seconds).
        if let override = ProcessInfo.processInfo.environment["NITS_DDC_DELAY"],
           let seconds = Double(override),
           seconds > 0 {
            self.readDelay = seconds
        } else {
            self.readDelay = readDelay
        }
        self.symbols = symbols
    }

    var chipAddressHex: String {
        String(format: "0x%02X", chipAddress)
    }

    func write(code: UInt8, value: UInt16) -> Bool {
        guard let writeI2C = symbols.writeI2C else { return false }
        var packet = DDCPacket.setVCP(code, value: value)

        // Two send attempts, 10 ms apart. This is not belt-and-braces: several panels
        // ACK the first Set VCP without applying it, and apply the second. m1ddc ships
        // the same behavior. A single success is enough.
        var succeeded = false
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 0.01)
            let result = packet.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return writeI2C(service, chipAddress, 0x51, base, UInt32(raw.count))
            }
            if result == KERN_SUCCESS {
                succeeded = true
            }
        }
        return succeeded
    }

    func readRaw(code: UInt8) -> [UInt8]? {
        guard let readI2C = symbols.readI2C else { return nil }
        guard sendRequest(DDCPacket.getVCP(code)) else { return nil }

        // The display needs about 40 ms to prepare a DDC/CI reply; MCDP29xx needs 50 ms.
        Thread.sleep(forTimeInterval: readDelay)

        var reply = [UInt8](repeating: 0, count: 12)
        let read = reply.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return readI2C(service, chipAddress, 0x51, base, UInt32(raw.count))
        }
        guard read == KERN_SUCCESS else { return nil }
        return reply
    }

    func readCapabilitiesRaw(offset: Int) -> [UInt8]? {
        guard let readI2C = symbols.readI2C else { return nil }
        guard sendRequest(DDCPacket.capabilitiesRequest(offset: offset)) else { return nil }

        Thread.sleep(forTimeInterval: max(0.05, readDelay))

        var reply = [UInt8](repeating: 0, count: DDCCapabilitiesCodec.replyLength)
        let read = reply.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return readI2C(service, chipAddress, 0x51, base, UInt32(raw.count))
        }
        guard read == KERN_SUCCESS else { return nil }
        return reply
    }

    /// Sends a request packet twice, 10 ms apart. Several DCP-routed panels ACK the first
    /// request but only serve the second; a single send yields a DDC NULL frame
    /// (6E 80 ...). m1ddc ships the same double send, and this Dell U4921XO needs it for
    /// Get VCP as well as Set VCP.
    private func sendRequest(_ packet: [UInt8]) -> Bool {
        guard let writeI2C = symbols.writeI2C else { return false }
        var packet = packet
        var succeeded = false
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 0.01)
            let result = packet.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return writeI2C(service, chipAddress, 0x51, base, UInt32(raw.count))
            }
            if result == KERN_SUCCESS { succeeded = true }
        }
        return succeeded
    }
}

/// Builds and caches the display -> IOAVService map. The channel and the identity live in
/// sibling subtrees, so this does one depth-first walk and associates each channel with the
/// most recently seen DisplayAttributes block.
final class IOAVServiceProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [UInt32: IOAVChannel] = [:]
    private var topology: UInt64 = 0
    private var buildLock = NSLock()

    func channel(for display: DisplaySnapshot) -> IOAVChannel? {
        guard IOAVSymbols.shared.isAvailable else { return nil }

        lock.lock()
        if let cached = cache[display.id] {
            lock.unlock()
            return cached
        }
        let currentTopology = topology
        lock.unlock()

        buildLock.lock()
        defer { buildLock.unlock() }

        lock.lock()
        if let cached = cache[display.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Location-based pairing first: CoreDisplay names the display's framebuffer, and
        // the DCPAVServiceProxy under that framebuffer is the display's channel. This is
        // exact even with several identical monitors.
        if let direct = channelByLocation(display) {
            lock.lock()
            if currentTopology == topology { cache[display.id] = direct }
            lock.unlock()
            NitsLog.ddc.notice("DDC pairing: display \(display.id, privacy: .public) -> location match (chip \(direct.chipAddressHex, privacy: .public))")
            return direct
        }

        let (channels, identities) = walkRegistry()
        guard !channels.isEmpty else {
            NitsLog.ddc.error("no DCPAVServiceProxy channels found")
            return nil
        }

        var displayIDs: [UInt32] = []
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if CGGetOnlineDisplayList(count, &ids, &count) == .success {
            displayIDs = Array(ids.prefix(Int(count))).filter { CGDisplayIsBuiltin($0) == 0 }
        }

        let displays = displayIDs.map { id -> (id: UInt32, identity: DisplayIdentity) in
            (id, DisplayIdentity(
                vendor: CGDisplayVendorNumber(id),
                product: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                location: CoreDisplaySupport.location(for: id)
            ))
        }

        let result = DDCPairing.match(channels: identities, displays: displays)

        lock.lock()
        guard currentTopology == topology else {
            lock.unlock()
            return nil
        }
        for (displayID, index) in result.byDisplayID where index < channels.count {
            cache[displayID] = channels[index]
        }
        let found = cache[display.id]
        lock.unlock()

        let summary = result.byDisplayID.keys.sorted().map { id -> String in
            let index = result.byDisplayID[id] ?? -1
            return "display \(id) -> channel \(index)"
        }.joined(separator: ", ")
        NitsLog.ddc.notice("DDC pairing: \(summary, privacy: .public)\(result.ambiguous ? " (ambiguous, traversal fallback)" : "")")
        return found
    }

    func invalidate() {
        lock.lock()
        topology &+= 1
        cache.removeAll()
        lock.unlock()
    }

    /// Finds the AVService whose parent framebuffer is the display's IODisplayLocation.
    private func channelByLocation(_ display: DisplaySnapshot) -> IOAVChannel? {
        guard let location = display.identity.location ?? CoreDisplaySupport.location(for: display.id),
              !location.isEmpty
        else { return nil }

        let adapter = location.withCString { IORegistryEntryFromPath(kIOMainPortDefault, $0) }
        guard adapter != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(adapter) }

        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else {
            return nil
        }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var currentFramebuffer: UInt64?
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS {
                    currentFramebuffer = id
                }
                continue
            }

            guard currentFramebuffer == adapterID,
                  ioClassName(entry) == "DCPAVServiceProxy"
            else { continue }

            let location = property(entry, "Location") as? String
            guard location == nil || location == "External" else { continue }
            return makeChannel(entry)
        }
        return nil
    }

    private func makeChannel(_ proxy: io_service_t) -> IOAVChannel? {
        guard let createWithService = IOAVSymbols.shared.createWithService,
              let service = createWithService(nil, proxy)
        else { return nil }
        let isMCDP = isMCDP29XX(proxy)
        return IOAVChannel(
            service: service,
            chipAddress: isMCDP ? 0xB7 : 0x37,
            readDelay: isMCDP ? 0.05 : 0.04
        )
    }

    /// Some Macs route HDMI through an AppleDCPMCDP29XX controller, which expects DDC at
    /// chip address 0xB7 rather than 0x37. Writing at 0x37 ACKs but never reaches the panel.
    private func isMCDP29XX(_ proxy: io_service_t) -> Bool {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS,
              parent != 0
        else { return false }
        defer { IOObjectRelease(parent) }
        guard let providerClass = property(parent, "EPICProviderClass") as? String else {
            return false
        }
        return providerClass == "AppleDCPMCDP29XX"
    }

    private func walkRegistry() -> (channels: [IOAVChannel], identities: [DisplayIdentity?]) {
        guard IOAVSymbols.shared.createWithService != nil else { return ([], []) }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return ([], []) }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        let iteratorResult = IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard iteratorResult == KERN_SUCCESS else { return ([], []) }
        defer { IOObjectRelease(iterator) }

        var channels: [IOAVChannel] = []
        var identities: [DisplayIdentity?] = []
        var lastIdentity: DisplayIdentity?

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            if let attributes = property(entry, "DisplayAttributes") as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any],
               let identity = identity(from: product, location: registryPath(entry)) {
                lastIdentity = identity
            }

            guard ioClassName(entry) == "DCPAVServiceProxy" else { continue }

            let location = property(entry, "Location") as? String
            guard location == nil || location == "External" else { continue }

            guard let channel = makeChannel(entry) else { continue }
            channels.append(channel)
            identities.append(lastIdentity)
        }

        return (channels, identities)
    }

    private func property(_ entry: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private func identity(from product: [String: Any], location: String?) -> DisplayIdentity? {
        func u32(_ value: Any?) -> UInt32? {
            if let number = value as? NSNumber { return number.uint32Value }
            if let value = value as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: value)) }
            if let value = value as? UInt32 { return value }
            return nil
        }
        guard let vendor = u32(product["LegacyManufacturerID"]),
              let productID = u32(product["ProductID"])
        else { return nil }
        return DisplayIdentity(
            vendor: vendor,
            product: productID,
            serial: u32(product["SerialNumber"]) ?? 0,
            location: location
        )
    }

    private func registryPath(_ entry: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2048)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: buffer)
    }

    private func ioClassName(_ entry: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }
}
#endif

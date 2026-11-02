#if arch(x86_64)
import Foundation
import CoreGraphics
import IOKit
import IOKit.i2c

/// The Intel DDC path: IOFramebuffer I2C via IOFBCopyI2CInterfaceForBus.
final class IntelChannel: DDCChannel, @unchecked Sendable {
    private let framebuffer: io_service_t
    private let lock = NSLock()
    private var preferredBus: UInt32?

    init(framebuffer: io_service_t) {
        self.framebuffer = framebuffer
    }

    deinit {
        IOObjectRelease(framebuffer)
    }

    func write(code: UInt8, value: UInt16) -> Bool {
        let payload = DDCPacket.setVCP(code, value: value)
        return withBus { bus in
            self.send(payload, bus: bus, expectReply: false) != nil
        }
    }

    func readRaw(code: UInt8) -> [UInt8]? {
        let payload = DDCPacket.getVCP(code)
        return withBus { bus in
            self.send(payload, bus: bus, expectReply: true)
        }
    }

    func readCapabilitiesRaw(offset: Int) -> [UInt8]? {
        nil
    }

    private func withBus<T>(_ body: (UInt32) -> T?) -> T? {
        lock.lock()
        let cached = preferredBus
        lock.unlock()

        if let cached, let result = body(cached) {
            return result
        }
        for bus: UInt32 in 0..<8 {
            if bus == cached { continue }
            if let result = body(bus) {
                lock.lock()
                preferredBus = bus
                lock.unlock()
                return result
            }
        }
        return nil
    }

    private func send(_ payload: [UInt8], bus: UInt32, expectReply: Bool) -> [UInt8]? {
        var interface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS,
              interface != 0
        else { return nil }
        defer { IOObjectRelease(interface) }

        var connection: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, IOOptionBits(0), &connection) == KERN_SUCCESS,
              let connection
        else { return nil }
        defer { IOI2CInterfaceClose(connection, IOOptionBits(0)) }

        var reply = [UInt8](repeating: 0, count: expectReply ? 12 : 0)
        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = 0x6E
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendSubAddress = 0
        request.sendBytes = UInt32(payload.count)
        request.minReplyDelay = 50_000_000

        let ok = payload.withUnsafeMutableBytes { sendRaw -> Bool in
            guard let sendBase = sendRaw.baseAddress else { return false }
            request.sendBuffer = UInt(bitPattern: sendBase)

            if expectReply {
                reply.withUnsafeMutableBytes { replyRaw in
                    guard let replyBase = replyRaw.baseAddress else { return }
                    request.replyAddress = 0x6F
                    request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                    request.replySubAddress = 0
                    request.replyBuffer = UInt(bitPattern: replyBase)
                    request.replyBytes = UInt32(replyRaw.count)
                }
            } else {
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                request.replyBytes = 0
            }

            guard IOI2CSendRequest(connection, IOOptionBits(0), &request) == KERN_SUCCESS,
                  request.result == KERN_SUCCESS
            else { return false }
            return true
        }

        return ok && expectReply ? reply : (ok ? [] : nil)
    }
}

final class IntelDDCProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [UInt32: IntelChannel] = [:]
    private var topology: UInt64 = 0

    func channel(for display: DisplaySnapshot) -> IntelChannel? {
        guard !display.isBuiltin else { return nil }
        lock.lock()
        if let cached = cache[display.id] {
            lock.unlock()
            return cached
        }
        let currentTopology = topology
        lock.unlock()

        guard let framebuffer = findFramebuffer(vendor: display.identity.vendor, product: display.identity.product) else {
            return nil
        }
        let channel = IntelChannel(framebuffer: framebuffer)

        lock.lock()
        defer { lock.unlock() }
        guard currentTopology == topology else { return nil }
        cache[display.id] = channel
        return channel
    }

    func invalidate() {
        lock.lock()
        topology &+= 1
        cache.removeAll()
        lock.unlock()
    }

    private func findFramebuffer(vendor: UInt32, product: UInt32) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let dictionary = IODisplayCreateInfoDictionary(
                service,
                IOOptionBits(kIODisplayOnlyPreferredName)
            )?.takeRetainedValue() as NSDictionary? else { continue }

            let displayVendor = (dictionary["DisplayVendorID"] as? NSNumber)?.uint32Value ?? 0
            let displayProduct = (dictionary["DisplayProductID"] as? NSNumber)?.uint32Value ?? 0
            guard displayVendor == vendor, displayProduct == product else { continue }

            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0
            else { continue }
            return parent
        }
        return nil
    }
}
#endif

import Foundation
import CoreGraphics
import IOKit

/// Nominal SDR luminance ceilings used to show nits on the OSD and to compare unlike
/// panels. Apple publishes built-in values through CoreDisplay; external monitors carry
/// CTA luminance in the IORegistry DisplayAttributes block as 16.16 fixed point.
public enum DisplayLuminanceService {
    private static let plausible: ClosedRange<Double> = 40...10_000
    private static let lock = NSLock()
    private static var cachedNodes: [Node] = []
    private static var cachedAt = Date.distantPast

    private struct Node {
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
        let nits: Double?
    }

    public static func maximumSDRNits(displayID: CGDirectDisplayID, isBuiltin: Bool) -> Double? {
        if isBuiltin {
            guard let info = CoreDisplaySupport.infoDictionary(for: displayID) else { return nil }
            for key in ["NonReferencePeakSDRLuminance", "ReferencePeakSDRLuminance"] {
                if let number = info[key] as? NSNumber {
                    let value = number.doubleValue
                    if plausible.contains(value) { return value }
                }
            }
            return nil
        }

        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let nodes = registryNodes()
        let exact = nodes.first {
            $0.vendor == vendor && $0.product == product
                && (serial == 0 || $0.serial == 0 || $0.serial == serial)
        }
        return (exact ?? nodes.first { $0.vendor == vendor && $0.product == product })?.nits
    }

    private static func registryNodes() -> [Node] {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(cachedAt) < 5 { return cachedNodes }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return [] }
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var nodes: [Node] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let attributes = IORegistryEntryCreateCFProperty(
                entry,
                "DisplayAttributes" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  let vendor = u32(product["LegacyManufacturerID"]),
                  let productID = u32(product["ProductID"])
            else { continue }

            nodes.append(Node(
                vendor: vendor,
                product: productID,
                serial: u32(product["SerialNumber"]) ?? 0,
                nits: maximumNits(attributes["Luminance"] as? [String: Any])
            ))
        }

        cachedNodes = nodes
        cachedAt = Date()
        return nodes
    }

    private static func maximumNits(_ luminance: [String: Any]?) -> Double? {
        guard let raw = number(luminance?["Max"]), raw > 0 else { return nil }
        let value = raw > 10_000 ? raw / 65_536.0 : raw
        return plausible.contains(value) ? value : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    /// Registry IDs sometimes come back as 64-bit numbers that do not fit UInt32.
    /// Never trap on those; just skip the node.
    private static func u32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            let raw = number.uint64Value
            guard raw <= UInt64(UInt32.max) else { return nil }
            return UInt32(raw)
        }
        if let value = value as? UInt32 { return value }
        if let value = value as? Int, value >= 0, value <= Int(UInt32.max) {
            return UInt32(value)
        }
        return nil
    }
}

import Foundation
import CoreGraphics
import IOKit

public struct EDIDInfo: Codable, Sendable {
    public var manufacturer: String?
    public var productName: String?
    public var productCode: UInt16?
    public var serialNumber: UInt32?
    public var weekOfManufacture: Int?
    public var yearOfManufacture: Int?
    public var widthCM: Int?
    public var heightCM: Int?
    public var raw: Data

    public var rawHex: String {
        raw.map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads the raw EDID block from the display's framebuffer entry and decodes the fields
/// humans care about. No private calls: EDID is a normal IORegistry property.
public enum EDIDService {
    public static func read(display: DisplaySnapshot) -> EDIDInfo? {
        guard let data = rawEDID(display: display), data.count >= 128, data[0] == 0x00 else {
            return nil
        }
        return decode(data)
    }

    public static func rawEDID(display: DisplaySnapshot) -> Data? {
        if let location = display.identity.location ?? CoreDisplaySupport.location(for: display.id) {
            let entry = location.withCString { IORegistryEntryFromPath(kIOMainPortDefault, $0) }
            if entry != IO_OBJECT_NULL {
                defer { IOObjectRelease(entry) }
                if let direct = property(entry, "EDID") as? Data, direct.count >= 128 {
                    return direct
                }
                if let metadata = property(entry, "Metadata") as? [String: Any],
                   let nested = metadata["EDID"] as? Data,
                   nested.count >= 128 {
                    return nested
                }
                let key = "EDID" as CFString
                if let searched = IORegistryEntrySearchCFProperty(
                    entry,
                    kIOServicePlane,
                    key,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively)
                ) as? Data,
                   searched.count >= 128 {
                    return searched
                }
            }
        }

        // On Apple Silicon the EDID block often lives on a sibling of the framebuffer
        // (a DCP node's Metadata dictionary). Walk the registry and match the display's
        // product ID, which is what the Metadata block carries.
        if let global = globalEDID(display: display) { return global }

        // Last resort on systems with IODisplayConnect (notably Intel).
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
            let vendor = (dictionary["DisplayVendorID"] as? NSNumber)?.uint32Value ?? 0
            let product = (dictionary["DisplayProductID"] as? NSNumber)?.uint32Value ?? 0
            guard vendor == display.identity.vendor, product == display.identity.product else { continue }
            if let data = dictionary["EDID"] as? Data, data.count >= 128 { return data }
        }
        return nil
    }

    private static func globalEDID(display: DisplaySnapshot) -> Data? {
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

        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            if let metadata = property(entry, "Metadata") as? [String: Any],
               let product = (metadata["ProductID"] as? NSNumber)?.uint32Value,
               product == display.identity.product,
               let edid = metadata["EDID"] as? Data,
               edid.count >= 128 {
                return edid
            }

            if let edid = property(entry, "EDID") as? Data,
               edid.count >= 128,
               let attributes = property(entry, "DisplayAttributes") as? [String: Any],
               let productAttributes = attributes["ProductAttributes"] as? [String: Any],
               let product = (productAttributes["ProductID"] as? NSNumber)?.uint32Value,
               product == display.identity.product {
                return edid
            }
        }
        return nil
    }

    // MARK: - Decode

    private static func decode(_ data: Data) -> EDIDInfo {
        let bytes = [UInt8](data)
        var info = EDIDInfo(raw: data)

        if bytes.count >= 18 {
            info.manufacturer = manufacturerName(bytes[8], bytes[9])
            info.productCode = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
            info.serialNumber = UInt32(bytes[12])
                | (UInt32(bytes[13]) << 8)
                | (UInt32(bytes[14]) << 16)
                | (UInt32(bytes[15]) << 24)
            info.weekOfManufacture = bytes[16] == 0 ? nil : Int(bytes[16])
            info.yearOfManufacture = bytes[17] == 0 ? nil : Int(bytes[17]) + 1990
            info.widthCM = bytes[21] == 0 ? nil : Int(bytes[21])
            info.heightCM = bytes[22] == 0 ? nil : Int(bytes[22])
        }

        // The four 18-byte descriptor blocks start at 54. 0xFC is the monitor name.
        var offset = 54
        while offset + 18 <= min(bytes.count, 126) {
            let block = Array(bytes[offset..<(offset + 18)])
            if block[0] == 0, block[1] == 0, block[3] == 0xFC {
                let text = String(bytes: block[5..<18], encoding: .ascii)?
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: "\0", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let text, !text.isEmpty { info.productName = text }
            }
            offset += 18
        }
        return info
    }

    /// EDID packs three 5-bit letters into two bytes after the header.
    private static func manufacturerName(_ high: UInt8, _ low: UInt8) -> String? {
        let value = (UInt16(high) << 8) | UInt16(low)
        func letter(_ bits: UInt16) -> Character {
            Character(UnicodeScalar(UInt8(bits & 0x1F) + 64))
        }
        let letters = [letter(value >> 10), letter(value >> 5), letter(value)]
        guard letters.allSatisfy({ $0.isLetter }) else { return nil }
        return String(letters)
    }

    private static func property(_ entry: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}

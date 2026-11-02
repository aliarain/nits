import Foundation
import CoreGraphics
import ColorSync
import IOKit

/// CGDirectDisplayID-based enumeration plus the stable identity and metadata Nits needs.
public enum DisplayCatalog {
    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    public static func snapshot(for displayID: CGDirectDisplayID) -> DisplaySnapshot? {
        guard displayID != 0 else { return nil }
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        let uuid = uuid(for: displayID) ?? "v\(vendor)-m\(product)-s\(serial)"

        let registry = registryInfo(vendor: vendor, product: product, serial: serial)
        let name: String
        if builtin {
            name = "Built-in Display"
        } else {
            name = registry?.name
                ?? CoreDisplaySupport.productName(for: displayID)
                ?? productNameFromRegistry(displayID: displayID)
                ?? "Display \(displayID)"
        }

        let modes = DisplayModeQuery.modes(for: displayID)
        let native = modes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        let fallbackNative = (
            width: Int(CGDisplayPixelsWide(displayID)),
            height: Int(CGDisplayPixelsHigh(displayID))
        )
        let nativeWidth = native?.width ?? fallbackNative.width
        let nativeHeight = native?.height ?? fallbackNative.height
        let rotation = CGDisplayRotation(displayID)
        let rotated = Int(rotation.rounded()) % 180 != 0

        let bounds = CGDisplayBounds(displayID)
        return DisplaySnapshot(
            id: displayID,
            uuid: uuid,
            name: name,
            identity: DisplayIdentity(
                vendor: vendor,
                product: product,
                serial: serial,
                location: CoreDisplaySupport.location(for: displayID)
            ),
            isBuiltin: builtin,
            isMain: CGDisplayIsMain(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            bounds: DisplayBounds(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.size.width,
                height: bounds.size.height
            ),
            rotation: rotation,
            pixelWidth: Int(CGDisplayPixelsWide(displayID)),
            pixelHeight: Int(CGDisplayPixelsHigh(displayID)),
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            panelWidth: rotated ? nativeHeight : nativeWidth,
            panelHeight: rotated ? nativeWidth : nativeHeight,
            hasNativeBrightness: NativeBrightness.shared.canChange(displayID),
            maximumEDR: 1.0,
            nominalMaxNits: DisplayLuminanceService.maximumSDRNits(
                displayID: displayID,
                isBuiltin: builtin
            ),
            connection: builtin ? "Built-in" : (registry?.connection ?? "External")
        )
    }

    public static func snapshots() -> [DisplaySnapshot] {
        onlineDisplayIDs().compactMap { snapshot(for: $0) }
    }

    // MARK: - IORegistry identity

    private struct RegistryInfo {
        var name: String?
        var connection: String
    }

    /// On Apple Silicon the product name lives in the framebuffer's DisplayAttributes
    /// block rather than in an IODisplayConnect service. The CoreDisplay location is the
    /// framebuffer path, so read the attributes straight from that entry.
    private static func productNameFromRegistry(displayID: CGDirectDisplayID) -> String? {
        guard let location = CoreDisplaySupport.location(for: displayID) else { return nil }
        let entry = location.withCString { IORegistryEntryFromPath(kIOMainPortDefault, $0) }
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }

        if let attributes = IORegistryEntryCreateCFProperty(
            entry,
            "DisplayAttributes" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
           let product = attributes["ProductAttributes"] as? [String: Any],
           let name = product["ProductName"] as? String,
           !name.isEmpty {
            return name
        }
        return nil
    }

    private static func registryInfo(vendor: UInt32, product: UInt32, serial: UInt32) -> RegistryInfo? {
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

            let serviceVendor = (dictionary["DisplayVendorID"] as? NSNumber)?.uint32Value ?? 0
            let serviceProduct = (dictionary["DisplayProductID"] as? NSNumber)?.uint32Value ?? 0
            let serviceSerial = (dictionary["DisplaySerialNumber"] as? NSNumber)?.uint32Value ?? 0
            guard serviceVendor == vendor, serviceProduct == product else { continue }
            if serial != 0, serviceSerial != 0, serviceSerial != serial { continue }

            var name = dictionary["DisplayProductName"] as? String
            if name == nil, let names = dictionary["DisplayProductName"] as? [String: String] {
                name = names["en_US"] ?? names.values.first
            }

            var connection = "External"
            var path = [CChar](repeating: 0, count: 2048)
            if IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS {
                let text = String(cString: path).lowercased()
                if text.contains("displaylink") { connection = "DisplayLink" }
                else if text.contains("hdmi") { connection = "HDMI" }
                else if text.contains("displayport") || text.contains("dcpav") { connection = "DisplayPort" }
            }
            return RegistryInfo(name: name, connection: connection)
        }
        return nil
    }
}

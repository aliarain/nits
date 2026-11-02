import Foundation
import CoreGraphics
import IOKit

public struct HiDPIInstallResult: Sendable {
    public let succeeded: Bool
    public let message: String?
    public let prompted: Bool

    public init(succeeded: Bool, message: String?, prompted: Bool) {
        self.succeeded = succeeded
        self.message = message
        self.prompted = prompted
    }
}

/// Installs the `scale-resolutions` display override plist macOS uses to expose HiDPI
/// modes. The directory is root-owned, so writes go through one administrator prompt.
/// The dense ladder (16-point steps) is what makes smooth scaling feel continuous.
public enum HiDPIOverride {
    public static let overridesBase = "/Library/Displays/Contents/Resources/Overrides"

    // MARK: - Pure planning

    public static func coarseLogicalSizes(
        nativeWidth: Int,
        nativeHeight: Int
    ) -> [(width: Int, height: Int)] {
        var result: [(Int, Int)] = [(nativeWidth, nativeHeight)]
        for scale in [0.75, 0.625, 0.5] {
            let width = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let height = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard width >= 800, height >= 600 else { continue }
            result.append((width, height))
        }
        return result
    }

    /// Native width stepped down by 16 points with the panel's aspect held, down to
    /// `minScale`. BetterDisplay uses the same 16-point grid; every stop keeps the 2x
    /// backing an integer.
    public static func smoothLogicalSizes(
        nativeWidth: Int,
        nativeHeight: Int,
        minScale: Double = 0.5
    ) -> [(width: Int, height: Int)] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let minimum = Int((Double(nativeWidth) * minScale).rounded())
        var result: [(Int, Int)] = []
        var width = nativeWidth
        while width >= minimum {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            if width >= 800, height >= 600 {
                result.append((width, height))
            }
            width -= 16
        }
        return result
    }

    /// 8-byte big-endian backing (pixel) size, as the override plist expects.
    public static func scaleResolutionData(width: Int, height: Int) -> Data {
        let backingWidth = width * 2
        let backingHeight = height * 2
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = UInt8((backingWidth >> 24) & 0xFF)
        bytes[1] = UInt8((backingWidth >> 16) & 0xFF)
        bytes[2] = UInt8((backingWidth >> 8) & 0xFF)
        bytes[3] = UInt8(backingWidth & 0xFF)
        bytes[4] = UInt8((backingHeight >> 24) & 0xFF)
        bytes[5] = UInt8((backingHeight >> 16) & 0xFF)
        bytes[6] = UInt8((backingHeight >> 8) & 0xFF)
        bytes[7] = UInt8(backingHeight & 0xFF)
        return Data(bytes)
    }

    public static func plistXML(scaleResolutions: [Data]) -> String {
        let entries = scaleResolutions
            .map { "        <data>\($0.base64EncodedString())</data>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>scale-resolutions</key>
            <array>
        \(entries)
            </array>
        </dict>
        </plist>
        """
    }

    // MARK: - Paths

    public static func directory(vendor: UInt32) -> String {
        overridesBase + String(format: "/DisplayVendorID-%x", vendor)
    }

    public static func plistPath(vendor: UInt32, product: UInt32) -> String {
        directory(vendor: vendor) + String(format: "/DisplayProductID-%x", product)
    }

    public static func isInstalled(vendor: UInt32, product: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(vendor: vendor, product: product))
    }

    public static func installedScaleResolutions(vendor: UInt32, product: UInt32) -> [Data]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath(vendor: vendor, product: product))),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any],
              let entries = dictionary["scale-resolutions"] as? [Data]
        else { return nil }
        return entries
    }

    // MARK: - Install

    public static func enable(
        display: DisplaySnapshot,
        dense: Bool = false
    ) -> HiDPIInstallResult {
        guard !display.isBuiltin else {
            return HiDPIInstallResult(succeeded: false, message: "The built-in display already has HiDPI", prompted: false)
        }
        let width = display.panelWidth
        let height = display.panelHeight
        guard width > 0, height > 0 else {
            return HiDPIInstallResult(succeeded: false, message: "Display reports no native resolution", prompted: false)
        }

        let logical = dense
            ? smoothLogicalSizes(nativeWidth: width, nativeHeight: height)
            : coarseLogicalSizes(nativeWidth: width, nativeHeight: height)
        let entries = logical.map { scaleResolutionData(width: $0.width, height: $0.height) }

        if setMatches(existing: installedScaleResolutions(vendor: display.identity.vendor, product: display.identity.product), entries: entries) {
            triggerReenumeration(vendor: display.identity.vendor, product: display.identity.product)
            return HiDPIInstallResult(succeeded: true, message: "HiDPI override already installed", prompted: false)
        }

        let xml = plistXML(scaleResolutions: entries)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("nits-hidpi-\(UUID().uuidString).plist")
        do {
            try xml.write(to: temporary, atomically: true, encoding: .utf8)
        } catch {
            return HiDPIInstallResult(succeeded: false, message: "Could not write temporary plist: \(error.localizedDescription)", prompted: false)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let path = plistPath(vendor: display.identity.vendor, product: display.identity.product)
        let directory = directory(vendor: display.identity.vendor)
        let command = [
            "mkdir -p \(shellQuote(directory))",
            "cp \(shellQuote(temporary.path)) \(shellQuote(path))",
            "chmod 644 \(shellQuote(path))",
        ].joined(separator: " && ")

        let result = PrivilegedShell.runWithAdministrator(command)
        guard result.succeeded else {
            return HiDPIInstallResult(succeeded: false, message: result.message, prompted: true)
        }
        triggerReenumeration(vendor: display.identity.vendor, product: display.identity.product)
        return HiDPIInstallResult(succeeded: true, message: nil, prompted: true)
    }

    public static func disable(display: DisplaySnapshot) -> HiDPIInstallResult {
        let path = plistPath(vendor: display.identity.vendor, product: display.identity.product)
        guard FileManager.default.fileExists(atPath: path) else {
            return HiDPIInstallResult(succeeded: true, message: "No override installed", prompted: false)
        }
        let result = PrivilegedShell.runWithAdministrator("rm -f \(shellQuote(path))")
        guard result.succeeded else {
            return HiDPIInstallResult(succeeded: false, message: result.message, prompted: true)
        }
        triggerReenumeration(vendor: display.identity.vendor, product: display.identity.product)
        return HiDPIInstallResult(succeeded: true, message: nil, prompted: true)
    }

    private static func setMatches(existing: [Data]?, entries: [Data]) -> Bool {
        guard let existing else { return false }
        return Set(existing) == Set(entries)
    }

    /// Asks the matching IODisplay service to re-read its modes. A soft reconnect is
    /// still needed on many systems for the new modes to enumerate.
    public static func triggerReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else { return }
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
            guard serviceVendor == vendor, serviceProduct == product else { continue }
            IOServiceRequestProbe(service, 0)
            return
        }
    }
}

import Foundation
import CoreGraphics

/// Writes an EDID override for a display, preserving any HiDPI `scale-resolutions`
/// already installed. The override directory is root-owned, so installation uses one
/// administrator prompt. A malformed EDID can leave the display blank until the override
/// is removed, so the input is validated before anything is written.
public enum EDIDOverride {
    public static func validate(_ data: Data) -> String? {
        guard data.count >= 128 else { return "EDID must be at least 128 bytes" }
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard Array(data.prefix(8)) == header else { return "Not an EDID block (bad header)" }
        guard data.count % 128 == 0 else { return "EDID length must be a multiple of 128 bytes" }
        return nil
    }

    public static func install(
        display: DisplaySnapshot,
        edid: Data
    ) -> HiDPIInstallResult {
        if let problem = validate(edid) {
            return HiDPIInstallResult(succeeded: false, message: problem, prompted: false)
        }
        guard !display.isBuiltin else {
            return HiDPIInstallResult(
                succeeded: false,
                message: "Refusing to override the built-in display's EDID",
                prompted: false
            )
        }

        let path = HiDPIOverride.plistPath(
            vendor: display.identity.vendor,
            product: display.identity.product
        )
        var plist = existingPlist(at: path) ?? [:]
        plist["IODisplayEDID"] = edid

        return write(plist: plist, path: path, display: display)
    }

    public static func restore(display: DisplaySnapshot) -> HiDPIInstallResult {
        let path = HiDPIOverride.plistPath(
            vendor: display.identity.vendor,
            product: display.identity.product
        )
        guard var plist = existingPlist(at: path) else {
            return HiDPIInstallResult(
                succeeded: true,
                message: "No override installed",
                prompted: false
            )
        }
        guard plist["IODisplayEDID"] != nil else {
            return HiDPIInstallResult(
                succeeded: true,
                message: "No EDID override installed",
                prompted: false
            )
        }

        plist.removeValue(forKey: "IODisplayEDID")
        if plist.isEmpty || (plist.count == 0) {
            let result = PrivilegedShell.runWithAdministrator("rm -f \(shellQuote(path))")
            guard result.succeeded else {
                return HiDPIInstallResult(succeeded: false, message: result.message, prompted: true)
            }
        } else {
            let result = write(plist: plist, path: path, display: display)
            guard result.succeeded else { return result }
        }
        HiDPIOverride.triggerReenumeration(
            vendor: display.identity.vendor,
            product: display.identity.product
        )
        return HiDPIInstallResult(succeeded: true, message: nil, prompted: true)
    }

    private static func write(
        plist: [String: Any],
        path: String,
        display: DisplaySnapshot
    ) -> HiDPIInstallResult {
        guard PropertyListSerialization.propertyList(plist, isValidFor: .xml) else {
            return HiDPIInstallResult(
                succeeded: false,
                message: "Could not build the override plist",
                prompted: false
            )
        }
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            return HiDPIInstallResult(
                succeeded: false,
                message: "Could not encode the override plist: \(error.localizedDescription)",
                prompted: false
            )
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("nits-edid-\(UUID().uuidString).plist")
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            return HiDPIInstallResult(
                succeeded: false,
                message: "Could not write the temporary plist: \(error.localizedDescription)",
                prompted: false
            )
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let directory = HiDPIOverride.directory(vendor: display.identity.vendor)
        let command = [
            "mkdir -p \(shellQuote(directory))",
            "cp \(shellQuote(temporary.path)) \(shellQuote(path))",
            "chmod 644 \(shellQuote(path))",
        ].joined(separator: " && ")

        let result = PrivilegedShell.runWithAdministrator(command)
        guard result.succeeded else {
            return HiDPIInstallResult(succeeded: false, message: result.message, prompted: true)
        }
        HiDPIOverride.triggerReenumeration(
            vendor: display.identity.vendor,
            product: display.identity.product
        )
        return HiDPIInstallResult(succeeded: true, message: nil, prompted: true)
    }

    private static func existingPlist(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }
}

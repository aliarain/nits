import Foundation
import CoreGraphics
import ColorSync

public struct ICCProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let path: URL
    public let colorSpaceType: String
    public let deviceClass: String

    public init(name: String, path: URL, colorSpaceType: String, deviceClass: String) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.colorSpaceType = colorSpaceType
        self.deviceClass = deviceClass
    }

    /// Only RGB monitor/working-space profiles are safe to assign to a display.
    /// Printer/scanner/CMYK profiles can crash WindowServer building the display transform.
    public var isDisplayProfile: Bool {
        colorSpaceType == "RGB" && (deviceClass == "mntr" || deviceClass == "spac")
    }

    public static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

public final class ColorProfileService: @unchecked Sendable {
    public init() {}

    public static func loadProfile(at url: URL) -> ICCProfile? {
        profile(from: url)
    }

    public func enumerateProfiles(for displayUUID: String) async -> [ICCProfile] {
        await Task.detached(priority: .userInitiated) {
            let searchURLs = [
                URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"),
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/ColorSync/Profiles"),
            ]
            var profiles: [ICCProfile] = []
            var seen = Set<URL>()
            let manager = FileManager.default

            for directory in searchURLs {
                guard let enumerator = manager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                while let url = enumerator.nextObject() as? URL {
                    guard !seen.contains(url) else { continue }
                    let ext = url.pathExtension.lowercased()
                    guard ext == "icc" || ext == "icm" else { continue }
                    seen.insert(url)
                    if let profile = Self.profile(from: url) {
                        profiles.append(profile)
                    }
                }
            }

            return profiles
                .filter { $0.isDisplayProfile }
                .filter { profile in
                    let path = profile.path.path
                    guard path.contains("/ColorSync/Profiles/Displays/") else { return true }
                    return path.range(of: displayUUID, options: .caseInsensitive) != nil
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    public func currentProfileName(for displayID: CGDirectDisplayID) -> String {
        if let raw = ColorSyncProfileCreateWithDisplayID(displayID) {
            let profile = raw.takeRetainedValue()
            if let rawDescription = ColorSyncProfileCopyDescriptionString(profile) {
                let description = rawDescription.takeRetainedValue() as String
                if !description.isEmpty { return description }
            }
        }
        if let name = CGDisplayCopyColorSpace(displayID).name as String? {
            return friendly(name)
        }
        return "Unknown"
    }

    public func currentProfileURL(for displayID: CGDirectDisplayID) -> URL? {
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = rawUUID.takeRetainedValue()
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return nil }

        guard let rawInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, uuid) else { return nil }
        let info = rawInfo.takeRetainedValue() as NSDictionary
        let factoryProfiles = info["FactoryProfiles"] as? NSDictionary
        guard let activeMode = factoryProfiles?[profileIDKey] else { return nil }

        if let custom = info["CustomProfiles"] as? NSDictionary,
           let value = custom[activeMode] {
            if let url = value as? NSURL { return url as URL }
            if let text = value as? String { return URL(string: text) }
        }
        if let mode = factoryProfiles?[activeMode] as? NSDictionary,
           let value = mode["DeviceProfileURL"] {
            if let url = value as? NSURL { return url as URL }
            if let text = value as? String { return URL(string: text) }
        }
        return nil
    }

    @discardableResult
    public func setProfile(_ profile: ICCProfile, for displayID: CGDirectDisplayID) -> Bool {
        guard profile.isDisplayProfile else { return false }
        guard let rawUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return false }
        let uuid = rawUUID.takeRetainedValue()
        guard let deviceClass = kColorSyncDisplayDeviceClass?.takeUnretainedValue(),
              let profileIDKey = kColorSyncDeviceDefaultProfileID?.takeUnretainedValue()
        else { return false }

        let profileInfo: NSDictionary = [profileIDKey: profile.path as NSURL]
        return ColorSyncDeviceSetCustomProfiles(
            deviceClass,
            uuid,
            profileInfo as CFDictionary
        )
    }

    // MARK: - Parsing

    private static func profile(from url: URL) -> ICCProfile? {
        let name: String
        let colorSpace: String
        let deviceClass: String

        if let rawProfile = ColorSyncProfileCreateWithURL(url as CFURL, nil) {
            let profile = rawProfile.takeRetainedValue()
            if let rawDescription = ColorSyncProfileCopyDescriptionString(profile) {
                name = rawDescription.takeRetainedValue() as String
            } else {
                name = url.deletingPathExtension().lastPathComponent
            }
            let signatures = headerSignatures(profile)
            colorSpace = friendly(signatures.colorSpace)
            deviceClass = signatures.deviceClass
        } else {
            name = url.deletingPathExtension().lastPathComponent
            colorSpace = "RGB"
            deviceClass = ""
        }

        return ICCProfile(
            name: name,
            path: url,
            colorSpaceType: colorSpace,
            deviceClass: deviceClass
        )
    }

    /// ICC header bytes 12–15 are device class, 16–19 data colour space. The SDK returns
    /// the 4CC fields host-endian, so reverse them back to ASCII.
    private static func headerSignatures(_ profile: ColorSyncProfile) -> (deviceClass: String, colorSpace: String) {
        guard let raw = ColorSyncProfileCopyHeader(profile) else { return ("", "") }
        let data = raw.takeRetainedValue() as Data
        guard data.count >= 20 else { return ("", "") }

        func signature(_ range: Range<Int>) -> String {
            let bytes = Array([UInt8](data[range]).reversed())
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                  let text = String(bytes: bytes, encoding: .ascii)
            else { return "" }
            return text.trimmingCharacters(in: .whitespaces)
        }

        return (signature(12..<16), signature(16..<20))
    }

    private static func friendly(_ signature: String) -> String {
        switch signature {
        case "RGB": return "RGB"
        case "CMYK": return "CMYK"
        case "GRAY": return "Gray"
        case "Lab": return "Lab"
        case "XYZ": return "XYZ"
        default: return signature.isEmpty ? "Unknown" : signature
        }
    }

    private func friendly(_ name: String) -> String {
        if name == (CGColorSpace.displayP3 as String) { return "Display P3" }
        if name == (CGColorSpace.sRGB as String) { return "sRGB IEC61966-2.1" }
        if name == (CGColorSpace.adobeRGB1998 as String) { return "Adobe RGB (1998)" }
        if name == (CGColorSpace.genericRGBLinear as String) { return "Generic RGB Linear" }
        if name == (CGColorSpace.extendedSRGB as String) { return "Extended sRGB" }
        if name == (CGColorSpace.linearSRGB as String) { return "Linear sRGB" }
        if name == (CGColorSpace.extendedLinearSRGB as String) { return "Extended Linear sRGB" }
        if name == (CGColorSpace.genericGrayGamma2_2 as String) { return "Generic Gray Gamma 2.2" }
        if name.hasPrefix("kCGColorSpace") {
            return String(name.dropFirst("kCGColorSpace".count))
        }
        return name
    }
}

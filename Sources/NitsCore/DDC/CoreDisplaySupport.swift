import Foundation
import CoreGraphics
import IOKit

/// Optional private CoreDisplay lookup for the stable IORegistry location of a display.
/// The location is what lets two identical monitors be told apart after macOS reshuffles
/// CGDirectDisplayIDs. When the symbol is missing we fall back to vendor/product/serial.
enum CoreDisplaySupport {
    private typealias CreateInfoDictionary =
        @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let createInfo: CreateInfoDictionary? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY
        ) else { return nil }
        guard let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateInfoDictionary.self)
    }()

    static func infoDictionary(for displayID: CGDirectDisplayID) -> NSDictionary? {
        guard let createInfo,
              let dictionary = createInfo(displayID)?.takeRetainedValue() as NSDictionary?
        else { return nil }
        return dictionary
    }

    static func location(for displayID: CGDirectDisplayID) -> String? {
        infoDictionary(for: displayID)?[kIODisplayLocationKey] as? String
    }

    static func productName(for displayID: CGDirectDisplayID) -> String? {
        guard let createInfo,
              let dictionary = createInfo(displayID)?.takeRetainedValue() as NSDictionary?
        else { return nil }
        return dictionary["DisplayProductName"] as? String
    }
}

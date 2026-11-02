import Foundation
import CoreGraphics
import IOKit

/// macOS's own backlight control for the built-in panel and Apple external displays.
/// DisplayServices is private; every symbol is optional and every failure falls through
/// to software dimming rather than crashing.
public final class NativeBrightness: @unchecked Sendable {
    public static let shared = NativeBrightness()

    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

    private let setFunction: SetBrightness?
    private let getFunction: GetBrightness?
    private let canChangeFunction: CanChange?

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle else { return nil }
            return dlsym(handle, name)
        }
        setFunction = symbol("DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        getFunction = symbol("DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        canChangeFunction = symbol("DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChange.self) }
    }

    public static let appleVendorID: UInt32 = 0x0610

    public var isAvailable: Bool {
        getFunction != nil && setFunction != nil
    }

    public func canChange(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(displayID) != 0 { return true }
        guard CGDisplayVendorNumber(displayID) == Self.appleVendorID,
              let canChangeFunction
        else { return false }
        return canChangeFunction(displayID)
    }

    /// Percent (0...100), or nil when macOS does not drive this display's backlight.
    public func brightness(for displayID: CGDirectDisplayID) -> Double? {
        guard canChange(displayID), let getFunction else { return nil }
        var value: Float = 0
        guard getFunction(displayID, &value) == 0 else { return nil }
        return min(100, max(0, Double(value) * 100))
    }

    @discardableResult
    public func setBrightness(_ percent: Double, for displayID: CGDirectDisplayID) -> Bool {
        guard canChange(displayID), let setFunction else { return false }
        let clamped = min(100, max(0, percent)) / 100
        return setFunction(displayID, Float(clamped)) == 0
    }
}

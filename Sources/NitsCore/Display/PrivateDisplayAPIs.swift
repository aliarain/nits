import Foundation
import CoreGraphics

/// SkyLight's display enable/disable and rotation functions. Resolved dynamically so a
/// missing symbol (or a future macOS) degrades to "unsupported" instead of a launch crash.
public final class SkyLightSupport: @unchecked Sendable {
    public static let shared = SkyLightSupport()

    private typealias ConfigureEnabled =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias GetDisplayList =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
    private typealias SetRotation =
        @convention(c) (CGDirectDisplayID, Int32) -> CGError
    private typealias ConfigureMode =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    private let handle: UnsafeMutableRawPointer?
    private let configureEnabledFunction: ConfigureEnabled?
    private let getDisplayListFunction: GetDisplayList?
    private let setRotationFunction: SetRotation?
    private let configureModeFunction: ConfigureMode?

    private init() {
        let loadedHandle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        handle = loadedHandle
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            if let loadedHandle, let found = dlsym(loadedHandle, name) { return found }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }
        configureEnabledFunction = symbol("SLSConfigureDisplayEnabled").map {
            unsafeBitCast($0, to: ConfigureEnabled.self)
        }
        getDisplayListFunction = symbol("SLSGetDisplayList").map {
            unsafeBitCast($0, to: GetDisplayList.self)
        }
        setRotationFunction = symbol("SLSSetDisplayRotation").map {
            unsafeBitCast($0, to: SetRotation.self)
        }
        configureModeFunction = symbol("CGSConfigureDisplayMode").map {
            unsafeBitCast($0, to: ConfigureMode.self)
        }
    }

    public var canDisconnect: Bool {
#if arch(arm64)
        configureEnabledFunction != nil
#else
        false
#endif
    }

    public var canSetRotation: Bool {
        setRotationFunction != nil
    }

    public var canConfigureHiddenModes: Bool {
        configureModeFunction != nil
    }

    public func configureEnabled(_ config: CGDisplayConfigRef?, _ displayID: CGDirectDisplayID, _ enabled: Bool) -> CGError? {
        configureEnabledFunction?(config, displayID, enabled)
    }

    /// Every display SkyLight knows, including ones disabled via configureEnabled.
    public func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let getDisplayListFunction else { return [] }
        var count: UInt32 = 0
        guard getDisplayListFunction(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard getDisplayListFunction(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public func setRotation(_ displayID: CGDirectDisplayID, degrees: Int) -> CGError? {
        setRotationFunction?(displayID, Int32(degrees))
    }

    public func configureMode(_ config: CGDisplayConfigRef?, _ displayID: CGDirectDisplayID, mode: Int32) -> CGError? {
        configureModeFunction?(config, displayID, mode)
    }
}

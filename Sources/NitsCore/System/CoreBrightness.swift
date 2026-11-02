import Foundation

/// System Night Shift and True Tone through CoreBrightness's private clients.
/// Loaded at runtime; nothing is linked and every call degrades to unavailable.
public final class CoreBrightness: @unchecked Sendable {
    private let blueLightClient: NSObject?
    private let trueToneClient: NSObject?

    public init() {
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_LAZY
        ) != nil else {
            blueLightClient = nil
            trueToneClient = nil
            return
        }
        if let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
            blueLightClient = cls.init()
        } else {
            blueLightClient = nil
        }
        if let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
            trueToneClient = cls.init()
        } else {
            trueToneClient = nil
        }
    }

    public var nightShiftAvailable: Bool {
        blueLightClient != nil
    }

    public var trueToneAvailable: Bool {
        guard let client = trueToneClient else { return false }
        return Self.bool(client, "supported") && Self.bool(client, "available")
    }

    public func nightShiftEnabled() -> Bool {
        guard let client = blueLightClient else { return false }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector) else { return false }
        var buffer = [UInt8](repeating: 0, count: 64)
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
        let ok = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return unsafeBitCast(client.method(for: selector), to: Fn.self)(client, selector, base)
        }
        // CBBlueLightStatus begins { BOOL active; BOOL enabled; ... }.
        return ok && buffer[1] != 0
    }

    @discardableResult
    public func setNightShift(_ on: Bool) -> Bool {
        guard let client = blueLightClient else { return false }
        Self.setBool(client, "setEnabled:", on)
        return true
    }

    public func trueToneEnabled() -> Bool {
        guard let client = trueToneClient, trueToneAvailable else { return false }
        return Self.bool(client, "enabled")
    }

    @discardableResult
    public func setTrueTone(_ on: Bool) -> Bool {
        guard let client = trueToneClient, trueToneAvailable else { return false }
        Self.setBool(client, "setEnabled:", on)
        return true
    }

    // MARK: - ObjC runtime helpers

    private static func bool(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: Fn.self)(object, selector)
    }

    private static func setBool(_ object: NSObject, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Fn.self)(object, selector, value)
    }
}

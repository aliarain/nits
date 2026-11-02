import Foundation
import CoreGraphics
import IOKit

public protocol DDCChannel: AnyObject, Sendable {
    /// Sends a Set VCP Feature request. True when the I2C transaction was accepted.
    func write(code: UInt8, value: UInt16) -> Bool

    /// Sends a Get VCP Feature request and returns the raw reply bytes.
    func readRaw(code: UInt8) -> [UInt8]?

    /// Nil when the transport cannot read capabilities (the Intel path).
    func readCapabilitiesRaw(offset: Int) -> [UInt8]?
}

public enum DDCChannelError: Error, CustomStringConvertible {
    case noChannel
    case transportUnavailable(String)
    case timedOut

    public var description: String {
        switch self {
        case .noChannel: return "No DDC channel"
        case .transportUnavailable(let why): return "DDC transport unavailable: \(why)"
        case .timedOut: return "DDC operation timed out"
        }
    }
}

/// Builds per-display channels. The default factory picks the Apple Silicon AVService
/// path or the Intel framebuffer path; tests inject their own.
public protocol DDCChannelProviding: AnyObject, Sendable {
    func channel(for display: DisplaySnapshot) -> DDCChannel?
    func invalidate()
}

public final class DefaultDDCChannelProvider: DDCChannelProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [UInt32: DDCChannel] = [:]
    private var generation: UInt64 = 0

#if arch(arm64)
    private let av = IOAVServiceProvider()
#else
    private let intel = IntelDDCProvider()
#endif

    public init() {}

    public func channel(for display: DisplaySnapshot) -> DDCChannel? {
        guard !display.isBuiltin else { return nil }

        lock.lock()
        if let cached = channels[display.id] {
            lock.unlock()
            return cached
        }
        let currentGeneration = generation
        lock.unlock()

#if arch(arm64)
        let found = av.channel(for: display)
#else
        let found = intel.channel(for: display)
#endif

        guard let found else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard currentGeneration == generation else { return nil }
        channels[display.id] = found
        return found
    }

    public func invalidate() {
        lock.lock()
        generation &+= 1
        channels.removeAll()
        lock.unlock()
#if arch(arm64)
        av.invalidate()
#else
        intel.invalidate()
#endif
    }
}

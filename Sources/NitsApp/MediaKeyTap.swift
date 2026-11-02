import AppKit
import ApplicationServices
import CoreGraphics
import NitsCore

/// Intercepts the hardware brightness/volume keys with a CGEventTap. This is the only
/// part of Nits that needs Accessibility permission; everything else works without it.
final class MediaKeyTap: @unchecked Sendable {
    enum Key: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    var handler: (@MainActor (Key) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let systemDefinedRaw = UInt32(NSEvent.EventType.systemDefined.rawValue)

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }

        let mask = CGEventMask(1 << Self.systemDefinedRaw)
        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: nitsMediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NitsLog.app.error("media key tap could not be created (Accessibility not granted)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        self.tap = machPort
        self.source = source
        NitsLog.app.notice("media key tap started")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        NitsLog.app.notice("media key tap stopped")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefinedRaw else {
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passUnretained(event) }

        let data = nsEvent.data1
        let code = Int32((data & 0xFFFF_0000) >> 16)
        let flags = data & 0x0000_FFFF
        let isKeyDown = ((flags & 0xFF00) >> 8) == 0x0A
        guard let key = Key(rawValue: code) else {
            return Unmanaged.passUnretained(event)
        }
        if isKeyDown {
            let handler = handler
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handler?(key)
                }
            }
        }
        // Swallow both press and release so macOS does not also show its own OSD.
        return nil
    }

    deinit {
        stop()
    }
}

private func nitsMediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

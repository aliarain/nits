import Foundation
import Carbon.HIToolbox

public struct HotkeyRegistration: Sendable {
    public var binding: HotkeyBinding
    public var action: HotkeyAction

    public init(binding: HotkeyBinding, action: HotkeyAction) {
        self.binding = binding
        self.action = action
    }
}

/// Global shortcuts through Carbon's RegisterEventHotKey: no Accessibility permission,
/// works while another app has focus, and survives menu bar app activation policy.
public final class HotkeyCenter: @unchecked Sendable {
    private let lock = NSLock()
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: HotkeyAction)] = [:]
    private var nextID: UInt32 = 1
    private var suspensions = 0
    private var onAction: (@Sendable (HotkeyAction) -> Void)?

    public init() {
        HotkeyCenterRegistry.shared.attach(self)
    }

    public func setHandler(_ handler: @escaping @Sendable (HotkeyAction) -> Void) {
        lock.withLock { onAction = handler }
    }

    public func beginSuspension() {
        lock.withLock { suspensions += 1 }
        sync([])
    }

    public func endSuspension() {
        lock.withLock { suspensions = max(0, suspensions - 1) }
    }

    /// Replaces every registration. Called on launch and whenever config changes.
    public func sync(_ registrations: [HotkeyRegistration]) {
        lock.lock()
        for entry in self.registrations.values {
            UnregisterEventHotKey(entry.ref)
        }
        self.registrations.removeAll()

        guard suspensions == 0 else {
            lock.unlock()
            return
        }
        lock.unlock()

        for registration in registrations {
            register(registration)
        }
    }

    private func register(_ registration: HotkeyRegistration) {
        installHandlerIfNeeded()
        lock.lock()
        let id = nextID
        nextID &+= 1
        lock.unlock()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E69_7473), id: id)
        let status = RegisterEventHotKey(
            registration.binding.keyCode,
            registration.binding.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard let ref else {
            NitsLog.hotkey.error("RegisterEventHotKey failed (\(status, privacy: .public)) for \(registration.binding.label, privacy: .public)")
            return
        }
        lock.lock()
        registrations[id] = (ref, registration.action)
        lock.unlock()
    }

    private func installHandlerIfNeeded() {
        lock.lock()
        let alreadyInstalled = handlerRef != nil
        lock.unlock()
        guard !alreadyInstalled else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        ]
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let id = hotKeyID.id
            DispatchQueue.main.async {
                HotkeyCenterRegistry.shared.fire(id: id)
            }
            return noErr
        }, eventTypes.count, &eventTypes, nil, &handlerRef)

        if status != noErr {
            NitsLog.hotkey.error("InstallEventHandler failed (\(status, privacy: .public))")
        }
    }

    fileprivate func fire(id: UInt32) {
        let entry = lock.withLock { registrations[id] }
        guard let action = entry?.action else { return }
        let handler = lock.withLock { onAction }
        handler?(action)
    }

    deinit {
        for entry in registrations.values {
            UnregisterEventHotKey(entry.ref)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

/// The Carbon callback has no context pointer of its own, so the process-wide center is
/// reached through this registry. One instance per process is all Carbon supports anyway.
private final class HotkeyCenterRegistry: @unchecked Sendable {
    static let shared = HotkeyCenterRegistry()
    private let lock = NSLock()
    private weak var center: HotkeyCenter?

    func attach(_ center: HotkeyCenter) {
        lock.withLock { self.center = center }
    }

    func fire(id: UInt32) {
        let center = lock.withLock { self.center }
        center?.fire(id: id)
    }
}

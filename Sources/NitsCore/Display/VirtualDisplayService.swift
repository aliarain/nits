import Foundation
import CoreGraphics
import NitsPrivate

public struct VirtualDisplayConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    public var hiDPI: Bool
    public var autoCreate: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        width: Int,
        height: Int,
        refreshRate: Double = 60,
        hiDPI: Bool = true,
        autoCreate: Bool = true
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
        self.autoCreate = autoCreate
    }

    public var label: String {
        "\(width)×\(height)\(hiDPI ? " HiDPI" : "") @ \(Int(refreshRate)) Hz"
    }
}

/// Owns the lifecycle of CGVirtualDisplay objects. This is the foundation for PIP,
/// streaming, beyond-cap HiDPI and preconfigured virtual screens.
public final class VirtualDisplayService: @unchecked Sendable {
    public static let virtualVendorID: UInt32 = 0xEEEE

    /// Carries the non-Sendable C pointer across concurrency boundaries; only this
    /// service creates, uses and destroys it, serially per configuration.
    private final class Handle: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init(_ pointer: UnsafeMutableRawPointer) {
            self.pointer = pointer
        }
    }

    private let config: ConfigStore
    private let lock = NSLock()
    private var handles: [UUID: Handle] = [:]
    private var displayIDs: [UUID: CGDirectDisplayID] = [:]

    public init(config: ConfigStore) {
        self.config = config
    }

    public var configs: [VirtualDisplayConfig] {
        config.snapshot().virtualDisplays ?? []
    }

    public func isActive(_ id: UUID) -> Bool {
        lock.withLock { handles[id] != nil }
    }

    public func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayVendorNumber(displayID) == Self.virtualVendorID { return true }
        return lock.withLock { displayIDs.values.contains(displayID) }
    }

    public func name(for displayID: CGDirectDisplayID) -> String? {
        let configID: UUID? = lock.withLock {
            displayIDs.first { $0.value == displayID }?.key
        }
        if let configID, let name = configs.first(where: { $0.id == configID })?.name {
            return name
        }
        // A CLI process has no live handle map. Match the surviving virtual display to
        // its configuration by pixel size, or fall back to the only config.
        let configurations = configs
        let width = Int(CGDisplayPixelsWide(displayID))
        let height = Int(CGDisplayPixelsHigh(displayID))
        if let match = configurations.first(where: { $0.width == width && $0.height == height }) {
            return match.name
        }
        if configurations.count == 1 { return configurations[0].name }
        return nil
    }

    @discardableResult
    public func create(_ configuration: VirtualDisplayConfig) async -> Bool {
        guard configuration.width > 0, configuration.height > 0 else { return false }
        if isActive(configuration.id) { return true }
        // A virtual display left behind by a crash would otherwise duplicate on autoCreate.
        if configs.contains(where: { $0.id == configuration.id }),
           onlineVirtualDisplays().contains(where: { CGDisplayVendorNumber($0) == Self.virtualVendorID }),
           handles.isEmpty {
            // Best effort: assume a same-vendor survivor is ours and do not create a second.
            return false
        }

        let uuid = configuration.id.uuid
        let productID = UInt32(uuid.0) << 24 | UInt32(uuid.1) << 16 | UInt32(uuid.2) << 8 | UInt32(uuid.3)
        let serial = UInt32(uuid.4) << 24 | UInt32(uuid.5) << 16 | UInt32(uuid.6) << 8 | UInt32(uuid.7)

        let handle: Handle? = await MainActor.run {
            let name = configuration.name.isEmpty ? "Nits Virtual" : configuration.name
            let pointer = name.withCString {
                NitsVirtualDisplayCreate(
                    $0,
                    UInt32(configuration.width),
                    UInt32(configuration.height),
                    Self.virtualVendorID,
                    productID,
                    serial
                )
            }
            return pointer.map(Handle.init)
        }
        guard let handle else {
            NitsLog.display.error("virtual display could not be created")
            return false
        }

        let applied = await withTimeout(seconds: 10, fallback: false) {
            NitsVirtualDisplayApply(
                handle.pointer,
                UInt32(configuration.width),
                UInt32(configuration.height),
                configuration.refreshRate,
                configuration.hiDPI
            )
        }
        guard applied else {
            NitsVirtualDisplayDestroy(handle.pointer)
            NitsLog.display.error("virtual display apply failed")
            return false
        }

        let displayID = NitsVirtualDisplayID(handle.pointer)
        guard displayID != kCGNullDirectDisplay else {
            NitsVirtualDisplayDestroy(handle.pointer)
            return false
        }

        lock.withLock {
            handles[configuration.id] = handle
            displayIDs[configuration.id] = displayID
        }
        NitsLog.display.notice("virtual display \(configuration.name, privacy: .public) online as \(displayID, privacy: .public)")

        // macOS assigns its own scaled default asynchronously; prefer the native 1x mode.
        await applyNativeMode(displayID: displayID, width: configuration.width, height: configuration.height)
        return true
    }

    @discardableResult
    public func add(_ configuration: VirtualDisplayConfig) async -> Bool {
        guard await create(configuration) else { return false }
        persist { config in
            var list = config.virtualDisplays ?? []
            list.removeAll { $0.id == configuration.id }
            list.append(configuration)
            config.virtualDisplays = list
        }
        return true
    }

    public func remove(id: UUID) {
        lock.lock()
        let handle = handles.removeValue(forKey: id)
        displayIDs.removeValue(forKey: id)
        lock.unlock()
        if let handle { NitsVirtualDisplayDestroy(handle.pointer) }
        persist { config in
            config.virtualDisplays?.removeAll { $0.id == id }
        }
    }

    public func setAutoCreate(_ on: Bool, id: UUID) {
        persist { config in
            var list = config.virtualDisplays ?? []
            if let index = list.firstIndex(where: { $0.id == id }) {
                list[index].autoCreate = on
            }
            config.virtualDisplays = list
        }
    }

    public func destroyAll() {
        lock.lock()
        let all = Array(handles.values)
        handles.removeAll()
        displayIDs.removeAll()
        lock.unlock()
        for handle in all { NitsVirtualDisplayDestroy(handle.pointer) }
    }

    /// Recreates autoCreate configurations once after launch. Called from the runtime's
    /// startMonitoring after WindowServer has settled.
    public func restoreAutoCreate() {
        let auto = configs.filter(\.autoCreate)
        guard !auto.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            for configuration in auto where !self.isActive(configuration.id) {
                _ = await self.create(configuration)
            }
        }
    }

    // MARK: - Helpers

    private func onlineVirtualDisplays() -> [CGDirectDisplayID] {
        DisplayCatalog.onlineDisplayIDs().filter {
            CGDisplayVendorNumber($0) == Self.virtualVendorID
        }
    }

    private func applyNativeMode(displayID: CGDirectDisplayID, width: Int, height: Int) async {
        let modes = DisplayModeQuery.modes(for: displayID)
        guard let native = modes.first(where: {
            $0.width == width && $0.pixelWidth == width && $0.height == height
        }) ?? modes.first(where: { $0.pixelWidth == width && $0.pixelHeight == height })
        else { return }
        _ = await ResolutionController().apply(native, to: displayID)
    }

    private func persist(_ mutate: (inout NitsConfig) -> Void) {
        config.update { mutate(&$0) }
    }
}

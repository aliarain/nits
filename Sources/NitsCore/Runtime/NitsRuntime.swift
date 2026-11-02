import AppKit
import Foundation
import CoreGraphics

public struct DisplayState: Codable, Sendable {
    public var display: DisplaySnapshot
    public var brightness: Double?
    public var volume: Double?
    public var backend: BrightnessBackend
    public var volumeSupported: Bool?
    public var modes: [DisplayModeInfo]
    public var currentMode: DisplayModeInfo?
    public var gamma: GammaAdjustment
    public var hdrSoftware: Bool
    public var extraBrightness: Bool
    public var overlayDimming: Bool
    public var forcedVolume: Bool
    public var maxBrightness: UInt16?
    public var disconnected: Bool

    public var isOnline: Bool { !disconnected }
}

/// The shared composition root used by both the menu bar app and `nitsctl`.
/// Controllers do one job each; this type owns persistence, display-change recovery and
/// the small policies that span them (sync groups, hotkeys, presets).
public final class NitsRuntime: @unchecked Sendable {
    public let config: ConfigStore
    public let ddc: DDCEngine
    public let gamma: GammaEngine
    public let brightness: BrightnessController
    public let volume: VolumeController
    public let hardware: HardwareControls
    public let input: InputController
    public let resolution: ResolutionController
    public let arrangement: ArrangementController
    public let disconnect: DisconnectController
    public let monitor: DisplayMonitor
    public let presets: PresetEngine
    public let hotkeys: HotkeyCenter
    public let keepAwake: KeepAwake
    public let coreBrightness: CoreBrightness
    public let colorProfiles: ColorProfileService
    public let virtualDisplays: VirtualDisplayService

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var previousIDs: Set<UInt32> = []
    private var previousSnapshots: [UInt32: DisplaySnapshot] = [:]
    private var seenUUIDs: Set<String> = []
    private var runningActions: Set<String> = []
    private var syncing = false
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "app.nits.config.save", qos: .utility)

    public init(configURL: URL = NitsPaths.configFile) {
        let store = ConfigStore(url: configURL)
        config = store
        ddc = DDCEngine()
        gamma = GammaEngine()
        brightness = BrightnessController(ddc: ddc, gamma: gamma)
        volume = VolumeController(ddc: ddc)
        hardware = HardwareControls(ddc: ddc)
        input = InputController(ddc: ddc)
        resolution = ResolutionController()
        arrangement = ArrangementController()
        disconnect = DisconnectController(ddc: ddc)
        monitor = DisplayMonitor()
        presets = PresetEngine(config: store)
        hotkeys = HotkeyCenter()
        keepAwake = KeepAwake()
        coreBrightness = CoreBrightness()
        colorProfiles = ColorProfileService()
        virtualDisplays = VirtualDisplayService(config: store)

        presets.attach(self)
        disconnect.restoreRecords(store.snapshot().disconnected)
        for uuid in store.snapshot().general.syncGroup {
            _ = uuid
        }
        installDefaultHotkeyHandler()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    public func startMonitoring() {
        monitor.start()
        lock.lock()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .nitsDisplaysDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleDisplaysChanged()
            }
        }
        lock.unlock()

        if config.snapshot().general.keepAwake {
            _ = keepAwake.setActive(true)
        }
        virtualDisplays.restoreAutoCreate()
        handleDisplaysChanged()
    }

    public func stopMonitoring() {
        monitor.stop()
    }

    public func shutdown() {
        pendingSave?.cancel()
        config.save()
        hotkeys.sync([])
        monitor.stop()
        gamma.resetAll()
        virtualDisplays.destroyAll()
        _ = keepAwake.setActive(false)
    }

    // MARK: - Displays and state

    public func displays() -> [DisplaySnapshot] {
        let settings = config.snapshot().displaySettings
        return DisplayCatalog.snapshots().map { snapshot in
            var copy = snapshot
            if virtualDisplays.isVirtualDisplay(snapshot.id) {
                copy.isVirtual = true
                if let virtualName = virtualDisplays.name(for: snapshot.id), !virtualName.isEmpty {
                    copy.name = virtualName
                }
            }
            if let custom = settings[snapshot.uuid]?.customName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                copy.name = custom
            }
            return copy
        }
    }

    public func setDisplayName(_ name: String?, for display: DisplaySnapshot) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateSettings(display.uuid) {
            $0.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public func display(matching term: String?) -> DisplaySnapshot? {
        DisplaySelector.match(term, in: displays())
    }

    public func states(refresh: Bool = false) async -> [DisplayState] {
        let displays = displays()
        guard refresh else {
            var result: [DisplayState] = []
            for display in displays {
                result.append(await state(for: display, refresh: false))
            }
            return result
        }
        return await withTaskGroup(of: (Int, DisplayState).self) { group in
            for (index, display) in displays.enumerated() {
                group.addTask { (index, await self.state(for: display, refresh: true)) }
            }
            var collected: [(Int, DisplayState)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func state(for display: DisplaySnapshot, refresh: Bool = false) async -> DisplayState {
        let settings = config.snapshot().displaySettings[display.uuid] ?? DisplaySettings()
        var brightnessValue = brightness.lastPercent(for: display.id) ?? settings.brightness
        var volumeValue = volume.lastPercent(for: display.id) ?? settings.volume

        if refresh {
            if let fresh = await brightness.refreshBrightness(for: display) {
                brightnessValue = fresh
            }
            if !display.isBuiltin, let fresh = await volume.refreshVolume(for: display) {
                volumeValue = fresh
            }
        } else if brightnessValue == nil, display.hasNativeBrightness {
            brightnessValue = NativeBrightness.shared.brightness(for: display.id)
        }

        let modes = resolution.modes(for: display.id)
        let current = resolution.currentMode(for: display.id)
        var backend = brightness.backend(for: display.id)
        if backend == .unknown, display.hasNativeBrightness { backend = .native }

        return DisplayState(
            display: display,
            brightness: brightnessValue,
            volume: volumeValue,
            backend: backend,
            volumeSupported: volume.isSupported(display),
            modes: modes,
            currentMode: current,
            gamma: gamma.adjustment(for: display.id),
            hdrSoftware: settings.hdrSoftwareDimming ?? false,
            extraBrightness: settings.extraBrightness ?? false,
            overlayDimming: settings.overlayDimming ?? false,
            forcedVolume: settings.forcedVolume ?? false,
            maxBrightness: brightness.maximum(for: display.id),
            disconnected: disconnect.disconnectedDisplays().contains { $0.uuid == display.uuid }
        )
    }

    public func inputOptions(for display: DisplaySnapshot) async -> [InputOption] {
        await input.options(for: display)
    }

    // MARK: - Brightness

    @discardableResult
    public func setBrightness(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        let clamped = min(150, max(0, percent))
        let result = await brightness.setBrightness(clamped, for: display, wait: wait)
        updateSettings(display.uuid) { settings in
            settings.brightness = clamped
            if self.brightness.backend(for: display.id) == .software {
                settings.softwareFactor = clamped / 100
            }
        }

        var targets = brightnessSyncTargets(excluding: display)
        targets.append(contentsOf: groupTargets(for: display, keyPath: \.syncBrightness))
        let unique = Dictionary(grouping: targets, by: \.uuid).compactMap { $0.value.first }
        if !unique.isEmpty, beginGroupSync() {
            for other in unique {
                _ = await brightness.setBrightness(clamped, for: other, wait: wait)
                updateSettings(other.uuid) { $0.brightness = clamped }
            }
            endGroupSync()
        }
        return result
    }

    // MARK: - Display groups

    public func groups() -> [DisplayGroup] {
        config.snapshot().groups ?? []
    }

    public func saveGroup(_ group: DisplayGroup) {
        config.update { config in
            var list = config.groups ?? []
            if let index = list.firstIndex(where: { $0.id == group.id }) {
                list[index] = group
            } else {
                list.append(group)
            }
            config.groups = list
        }
    }

    public func deleteGroup(id: UUID) {
        config.update { config in
            config.groups?.removeAll { $0.id == id }
        }
    }

    private func groupTargets(
        for display: DisplaySnapshot,
        keyPath: KeyPath<DisplayGroup, Bool>
    ) -> [DisplaySnapshot] {
        let uuids = Set(
            groups()
                .filter { $0.displayUUIDs.contains(display.uuid) && $0[keyPath: keyPath] }
                .flatMap(\.displayUUIDs)
        )
        guard !uuids.isEmpty else { return [] }
        return displays().filter { uuids.contains($0.uuid) && $0.uuid != display.uuid }
    }

    private func beginGroupSync() -> Bool {
        lock.withLock { () -> Bool in
            guard !syncing else { return false }
            syncing = true
            return true
        }
    }

    private func endGroupSync() {
        lock.withLock { syncing = false }
    }

    public func adjustBrightness(by delta: Double, for display: DisplaySnapshot) async -> Double? {
        let current = brightness.lastPercent(for: display.id)
            ?? NativeBrightness.shared.brightness(for: display.id)
            ?? 50
        let target = min(150, max(0, current + delta))
        _ = await setBrightness(target, for: display, wait: false)
        return target
    }

    private func brightnessSyncTargets(excluding display: DisplaySnapshot) -> [DisplaySnapshot] {
        guard config.snapshot().general.syncBrightness else { return [] }
        let group = config.snapshot().general.syncGroup
        let displays = displays().filter { $0.uuid != display.uuid }
        if group.isEmpty { return displays }
        return displays.filter { group.contains($0.uuid) }
    }

    // MARK: - Volume, contrast and inputs

    @discardableResult
    public func setVolume(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        let result = await volume.setVolume(percent, for: display, wait: wait)
        updateSettings(display.uuid) { $0.volume = min(100, max(0, percent)) }
        let targets = groupTargets(for: display, keyPath: \.syncVolume)
        if !targets.isEmpty, beginGroupSync() {
            for other in targets where !other.isBuiltin {
                _ = await volume.setVolume(percent, for: other, wait: wait)
                updateSettings(other.uuid) { $0.volume = min(100, max(0, percent)) }
            }
            endGroupSync()
        }
        return result
    }

    public func adjustVolume(by delta: Double, for display: DisplaySnapshot) async -> Double? {
        let current = volume.lastPercent(for: display.id) ?? 50
        let target = min(100, max(0, current + delta))
        _ = await setVolume(target, for: display, wait: false)
        return target
    }

    @discardableResult
    public func setContrast(
        _ percent: Double,
        for display: DisplaySnapshot,
        wait: Bool = false
    ) async -> Bool? {
        let result = await hardware.setContrast(percent, for: display, wait: wait)
        updateSettings(display.uuid) { $0.contrast = min(100, max(0, percent)) }
        let targets = groupTargets(for: display, keyPath: \.syncImage)
        if !targets.isEmpty, beginGroupSync() {
            for other in targets where !other.isBuiltin {
                _ = await hardware.setContrast(percent, for: other, wait: wait)
                updateSettings(other.uuid) { $0.contrast = min(100, max(0, percent)) }
            }
            endGroupSync()
        }
        return result
    }

    @discardableResult
    public func setInput(_ value: UInt16, for display: DisplaySnapshot) async -> Bool {
        let ok = await input.setInput(value, for: display)
        if ok {
            updateSettings(display.uuid) { $0.lastInput = value }
        }
        let targets = groupTargets(for: display, keyPath: \.syncInput)
        if !targets.isEmpty, beginGroupSync() {
            for other in targets where !other.isBuiltin {
                _ = await input.setInput(value, for: other)
            }
            endGroupSync()
        }
        return ok
    }

    @discardableResult
    public func toggleMute(for display: DisplaySnapshot) async -> Bool {
        await volume.toggleMute(for: display)
    }

    // MARK: - Image adjustment

    public func setGamma(_ adjustment: GammaAdjustment, for display: DisplaySnapshot) {
        gamma.setAdjustment(adjustment, for: display.id)
        updateSettings(display.uuid) {
            $0.gamma = adjustment.isNeutral ? nil : adjustment
            $0.softwareFactor = self.gamma.softwareFactor(for: display.id)
        }
        let targets = groupTargets(for: display, keyPath: \.syncImage)
        if !targets.isEmpty, beginGroupSync() {
            for other in targets {
                gamma.setAdjustment(adjustment, for: other.id)
                updateSettings(other.uuid) {
                    $0.gamma = adjustment.isNeutral ? nil : adjustment
                    $0.softwareFactor = self.gamma.softwareFactor(for: other.id)
                }
            }
            endGroupSync()
        }
    }

    public func setHDRSoftwareDimming(_ on: Bool, for display: DisplaySnapshot) {
        brightness.setHDRSoftwareDimming(on, for: display.id)
        updateSettings(display.uuid) { $0.hdrSoftwareDimming = on }
    }

    public func setExtraBrightness(_ on: Bool, for display: DisplaySnapshot) {
        brightness.setExtraBrightness(on, for: display.id)
        updateSettings(display.uuid) { $0.extraBrightness = on }
    }

    /// Dim with a black overlay window instead of the gamma table, which allows true black.
    /// The overlay is drawn by the app; without one running this only saves the setting.
    public func setOverlayDimming(_ on: Bool, for display: DisplaySnapshot) {
        gamma.setOverlayMode(on, for: display.id)
        updateSettings(display.uuid) { $0.overlayDimming = on }
        if let percent = brightness.lastPercent(for: display.id) {
            Task { _ = await brightness.setBrightness(percent, for: display, wait: false) }
        }
    }

    /// Brings live overlay modes in line with the saved settings (after a CLI change).
    public func syncOverlayModes() {
        let saved = config.snapshot().displaySettings
        for display in DisplayCatalog.snapshots() {
            let wanted = saved[display.uuid]?.overlayDimming ?? false
            if gamma.isOverlayMode(for: display.id) != wanted {
                gamma.setOverlayMode(wanted, for: display.id)
                if let percent = brightness.lastPercent(for: display.id) {
                    Task { _ = await brightness.setBrightness(percent, for: display, wait: false) }
                }
            }
        }
    }

    public func setForcedVolume(_ on: Bool, for display: DisplaySnapshot) {
        volume.setForced(on, display: display)
        updateSettings(display.uuid) { $0.forcedVolume = on }
    }

    // MARK: - Resolution and arrangement

    @discardableResult
    public func setMode(
        width: Int,
        height: Int,
        refresh: Double?,
        hiDPI: Bool?,
        for display: DisplaySnapshot
    ) async -> Bool {
        let ok = await resolution.setResolution(
            width: width,
            height: height,
            refresh: refresh,
            hiDPI: hiDPI,
            for: display.id
        )
        if ok {
            PresetNotifications.postManualChange()
            let targets = groupTargets(for: display, keyPath: \.syncResolution)
            if !targets.isEmpty, beginGroupSync() {
                for other in targets {
                    _ = await resolution.setResolution(
                        width: width,
                        height: height,
                        refresh: refresh,
                        hiDPI: hiDPI,
                        for: other.id
                    )
                }
                endGroupSync()
            }
        }
        return ok
    }

    /// The ladder of "looks like" sizes for the display's current scaling, plus where the
    /// display sits on it. Nil when the display has no current mode.
    public func scaleLadder(for display: DisplaySnapshot) -> (modes: [DisplayModeInfo], index: Int)? {
        guard let current = resolution.currentMode(for: display.id) else { return nil }
        let ladder = DisplayModeInfo.scaleLadder(from: resolution.modes(for: display.id), current: current)
        guard let index = DisplayModeInfo.ladderIndex(of: current, in: ladder) else { return nil }
        return (ladder, index)
    }

    /// Moves along the ladder: positive steps give more space, negative give larger text.
    /// Clamps at both ends and reports false when already at the end or on failure.
    @discardableResult
    public func stepScale(by steps: Int, for display: DisplaySnapshot) async -> Bool {
        guard let (ladder, index) = scaleLadder(for: display) else { return false }
        let target = min(max(index + steps, 0), ladder.count - 1)
        guard target != index else { return false }
        return await setScale(ladder[target], for: display)
    }

    @discardableResult
    public func setScale(_ mode: DisplayModeInfo, for display: DisplaySnapshot) async -> Bool {
        await setMode(
            width: mode.width,
            height: mode.height,
            refresh: mode.refreshRate,
            hiDPI: mode.isHiDPI,
            for: display
        )
    }

    @discardableResult
    public func toggleHiDPI(for display: DisplaySnapshot) async -> Bool {
        await resolution.toggleHiDPI(for: display.id)
    }

    @discardableResult
    public func rotate(_ display: DisplaySnapshot, degrees: Int) async -> Bool {
        await resolution.rotate(display.id, degrees: degrees)
    }

    @discardableResult
    public func setMain(_ display: DisplaySnapshot) async -> Bool {
        await arrangement.setMain(display.id)
    }

    @discardableResult
    public func mirror(_ display: DisplaySnapshot, onto source: DisplaySnapshot) async -> Bool {
        await arrangement.mirror(display.id, onto: source.id)
    }

    @discardableResult
    public func unmirror(_ display: DisplaySnapshot) async -> Bool {
        await arrangement.unmirror(display.id)
    }

    // MARK: - Disconnect / reconnect

    public func disconnect(_ display: DisplaySnapshot) async -> Result<Void, DisconnectError> {
        let result = await disconnect.disconnect(display)
        syncDisconnectedRecords()
        return result
    }

    public func reconnect(uuid: String) async -> Result<Void, DisconnectError> {
        let result = await disconnect.reconnect(uuid: uuid)
        syncDisconnectedRecords()
        return result
    }

    public func softReconnect(_ display: DisplaySnapshot) async -> Bool {
        await disconnect.softReconnect(display)
    }

    public func disconnectedDisplays() -> [DisconnectedDisplay] {
        disconnect.disconnectedDisplays()
    }

    // MARK: - HiDPI

    public func enableHiDPI(_ display: DisplaySnapshot, dense: Bool = false) async -> HiDPIInstallResult {
        let result = HiDPIOverride.enable(display: display, dense: dense)
        if result.succeeded {
            _ = await disconnect.softReconnect(display)
        }
        return result
    }

    public func disableHiDPI(_ display: DisplaySnapshot) async -> HiDPIInstallResult {
        let result = HiDPIOverride.disable(display: display)
        if result.succeeded {
            _ = await disconnect.softReconnect(display)
        }
        return result
    }

    public func installEDIDOverride(
        _ edid: Data,
        for display: DisplaySnapshot
    ) async -> HiDPIInstallResult {
        let result = EDIDOverride.install(display: display, edid: edid)
        if result.succeeded {
            _ = await disconnect.softReconnect(display)
        }
        return result
    }

    public func restoreEDIDOverride(for display: DisplaySnapshot) async -> HiDPIInstallResult {
        let result = EDIDOverride.restore(display: display)
        if result.succeeded {
            _ = await disconnect.softReconnect(display)
        }
        return result
    }

    // MARK: - Sleep / wake

    public func snapshotForSleep() {
        for display in displays() {
            Task { await self.runEventAction(for: display, event: .sleep) }
        }
        resolution.snapshotModesForSleep()
        config.save()
    }

    public func handleWake() {
        Task {
            await resolution.restoreModesAfterWakeIfNeeded()
            for display in displays() {
                gamma.reapply(for: display.id)
                if let settings = config.snapshot().displaySettings[display.uuid],
                   let factor = settings.softwareFactor,
                   settings.brightness == nil {
                    gamma.setSoftwareFactor(factor, for: display.id)
                }
            }
            handleDisplaysChanged()
            for display in displays() {
                await self.runEventAction(for: display, event: .wake)
            }
        }
    }

    // MARK: - Display event actions

    public func eventAction(
        for display: DisplaySnapshot,
        event: DisplayEventAction.Event
    ) -> DisplayEventAction? {
        config.snapshot().displaySettings[display.uuid]?.eventActions?[event.rawValue]
    }

    public func setEventAction(
        _ action: DisplayEventAction?,
        for display: DisplaySnapshot,
        event: DisplayEventAction.Event
    ) {
        updateSettings(display.uuid) { settings in
            var actions = settings.eventActions ?? [:]
            if let action {
                actions[event.rawValue] = action
            } else {
                actions.removeValue(forKey: event.rawValue)
            }
            settings.eventActions = actions.isEmpty ? nil : actions
        }
    }

    private func runEventAction(
        for display: DisplaySnapshot,
        event: DisplayEventAction.Event
    ) async {
        guard let action = eventAction(for: display, event: event),
              action.kind != .preset || !action.value.isEmpty
        else { return }
        let key = "\(display.uuid):\(event.rawValue)"
        let claimed = lock.withLock { runningActions.insert(key).inserted }
        guard claimed else { return }
        defer { lock.withLock { _ = runningActions.remove(key) } }

        NitsLog.app.notice("display \(display.name, privacy: .public) \(event.rawValue, privacy: .public): running \(action.kind.rawValue, privacy: .public) action")
        switch action.kind {
        case .preset:
            let term = action.value
            guard let preset = presets.presets().first(where: {
                $0.id.uuidString.caseInsensitiveCompare(term) == .orderedSame
                    || $0.name.caseInsensitiveCompare(term) == .orderedSame
            }) else { return }
            _ = await presets.apply(preset)
        case .url:
            guard let url = URL(string: action.value) else { return }
            NSWorkspace.shared.open(url)
        case .script:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", action.value]
            try? process.run()
        }
    }

    // MARK: - Display-change recovery

    private func handleDisplaysChanged() {
        ddc.invalidateAll()
        let displays = displays()
        let ids = Set(displays.map(\.id))
        let uuids = Set(displays.map(\.uuid))

        lock.lock()
        let removed = previousIDs.subtracting(ids)
        let removedSnapshots = previousSnapshots.filter { removed.contains($0.key) }.map(\.value)
        previousIDs = ids
        previousSnapshots = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        seenUUIDs.formIntersection(uuids)
        lock.unlock()

        for snapshot in removedSnapshots {
            Task { await self.runEventAction(for: snapshot, event: .disconnect) }
        }

        for id in removed {
            brightness.invalidate(displayID: id)
            volume.invalidate(displayID: id)
            hardware.invalidate(displayID: id)
            gamma.reset(id)
        }

        disconnect.reconcile(online: displays)
        syncDisconnectedRecords()

        for display in displays {
            let isNew = lock.withLock { seenUUIDs.insert(display.uuid).inserted }
            if isNew {
                applyPersistedSettings(to: display)
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.runEventAction(for: display, event: .connect)
                }
            } else {
                gamma.reapply(for: display.id)
            }
        }
    }

    private func applyPersistedSettings(to display: DisplaySnapshot) {
        let settings = config.snapshot().displaySettings[display.uuid] ?? DisplaySettings()
        let general = config.snapshot().general

        if settings.forcedVolume == true {
            volume.setForced(true, display: display)
        }
        if let gammaAdjustment = settings.gamma {
            gamma.setAdjustment(gammaAdjustment, for: display.id)
        }
        if let factor = settings.softwareFactor, settings.brightness == nil {
            gamma.setSoftwareFactor(factor, for: display.id)
        }
        if settings.overlayDimming == true {
            gamma.setOverlayMode(true, for: display.id)
        }
        if settings.hdrSoftwareDimming == true {
            brightness.setHDRSoftwareDimming(true, for: display.id)
        }
        if settings.extraBrightness == true {
            brightness.setExtraBrightness(true, for: display.id)
        }
        if general.restoreBrightnessOnConnect, let saved = settings.brightness {
            Task { _ = await brightness.setBrightness(saved, for: display, wait: false) }
        }
        if let mode = settings.defaultMode {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                _ = await self?.setMode(
                    width: mode.width,
                    height: mode.height,
                    refresh: mode.refreshRate,
                    hiDPI: mode.hiDPI,
                    for: display
                )
            }
        }
    }

    public func setCurrentModeAsDefault(for display: DisplaySnapshot) {
        guard let mode = resolution.currentMode(for: display.id) else { return }
        updateSettings(display.uuid) { $0.defaultMode = ModeSpec(mode: mode) }
    }

    public func clearDefaultMode(for display: DisplaySnapshot) {
        updateSettings(display.uuid) { $0.defaultMode = nil }
    }

    // MARK: - Persistence helpers

    private func updateSettings(_ uuid: String, _ mutate: (inout DisplaySettings) -> Void) {
        config.update(persist: false) { config in
            var settings = config.displaySettings[uuid] ?? DisplaySettings()
            mutate(&settings)
            config.displaySettings[uuid] = settings
        }
        scheduleSave()
    }

    public func updateGeneral(_ mutate: (inout GeneralSettings) -> Void) {
        config.update { config in mutate(&config.general) }
        hotkeys.sync(hotkeyRegistrations())
    }

    private func syncDisconnectedRecords() {
        let records = disconnect.disconnectedDisplays()
        config.update(persist: false) { $0.disconnected = records }
        scheduleSave()
    }

    private func scheduleSave() {
        lock.lock()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.config.save() }
        pendingSave = work
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Hotkeys

    public func hotkeyRegistrations() -> [HotkeyRegistration] {
        let snapshot = config.snapshot()
        var result: [HotkeyRegistration] = []
        for (key, binding) in snapshot.general.hotkeys {
            switch key {
            case "brightnessUp": result.append(HotkeyRegistration(binding: binding, action: .brightnessUp))
            case "brightnessDown": result.append(HotkeyRegistration(binding: binding, action: .brightnessDown))
            case "volumeUp": result.append(HotkeyRegistration(binding: binding, action: .volumeUp))
            case "volumeDown": result.append(HotkeyRegistration(binding: binding, action: .volumeDown))
            case "toggleHiDPI": result.append(HotkeyRegistration(binding: binding, action: .toggleHiDPI))
            case "cycleInput": result.append(HotkeyRegistration(binding: binding, action: .cycleInput))
            case "toggleMute": result.append(HotkeyRegistration(binding: binding, action: .toggleMute))
            default: break
            }
        }
        for preset in snapshot.presets {
            if let binding = preset.hotkey {
                result.append(HotkeyRegistration(binding: binding, action: .preset(preset.id)))
            }
        }
        return result
    }

    public func syncHotkeys() {
        hotkeys.sync(hotkeyRegistrations())
    }

    private func installDefaultHotkeyHandler() {
        hotkeys.setHandler { [weak self] action in
            guard let self else { return }
            Task { await self.performHotkey(action) }
        }
    }

    private func performHotkey(_ action: HotkeyAction) async {
        let general = config.snapshot().general
        let displays = displays()
        guard let main = displays.first(where: \.isMain) ?? displays.first else { return }

        switch action {
        case .brightnessUp:
            _ = await adjustBrightness(by: general.brightnessStep, for: main)
        case .brightnessDown:
            _ = await adjustBrightness(by: -general.brightnessStep, for: main)
        case .volumeUp:
            _ = await adjustVolume(by: general.volumeStep, for: main)
        case .volumeDown:
            _ = await adjustVolume(by: -general.volumeStep, for: main)
        case .toggleMute:
            _ = await toggleMute(for: main)
        case .toggleHiDPI:
            _ = await toggleHiDPI(for: main)
        case .cycleInput:
            let options = await inputOptions(for: main)
            guard options.count > 1 else { return }
            let current = await input.currentInput(for: main)
            let index = options.firstIndex { $0.value == current } ?? -1
            let next = options[(index + 1) % options.count]
            _ = await setInput(next.value, for: main)
        case .preset(let id):
            guard let preset = presets.presets().first(where: { $0.id == id }) else { return }
            _ = await presets.apply(preset)
        }
    }

    // MARK: - System

    public func nightShiftEnabled() -> Bool {
        coreBrightness.nightShiftEnabled()
    }

    @discardableResult
    public func setNightShift(_ on: Bool) -> Bool {
        coreBrightness.setNightShift(on)
    }

    public func trueToneEnabled() -> Bool {
        coreBrightness.trueToneEnabled()
    }

    @discardableResult
    public func setTrueTone(_ on: Bool) -> Bool {
        coreBrightness.setTrueTone(on)
    }

    // MARK: - Color profiles

    public func profiles(for display: DisplaySnapshot) async -> [ICCProfile] {
        await colorProfiles.enumerateProfiles(for: display.uuid)
    }

    public func currentProfileName(for display: DisplaySnapshot) -> String {
        colorProfiles.currentProfileName(for: display.id)
    }

    @discardableResult
    public func setProfile(_ profile: ICCProfile, for display: DisplaySnapshot) -> Bool {
        colorProfiles.setProfile(profile, for: display.id)
    }

    @discardableResult
    public func setKeepAwake(_ on: Bool) -> Bool {
        let ok = keepAwake.setActive(on)
        if ok { updateGeneral { $0.keepAwake = on } }
        return ok
    }
}

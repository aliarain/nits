import AppKit
import Combine
import CoreGraphics
import ApplicationServices
import NitsCore

struct DisplayRowState: Identifiable {
    var state: DisplayState
    var brightness: Double?
    var volume: Double?
    var contrast: Double?
    var gamma: GammaAdjustment
    var inputs: [InputOption]?
    var currentInput: UInt16?
    var profiles: [ICCProfile]?
    var currentProfileName: String?
    var isExpanded = false
    var isBusy = false
    var inputsLoading = false

    var id: String { state.display.uuid }
    var display: DisplaySnapshot { state.display }

    var volumeSupported: Bool {
        state.volumeSupported == true || state.forcedVolume
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var rows: [DisplayRowState] = []
    @Published var disconnected: [DisconnectedDisplay] = []
    @Published var presets: [DisplayPreset] = []
    @Published var virtualConfigs: [VirtualDisplayConfig] = []
    @Published var groups: [DisplayGroup] = []
    @Published var settings: GeneralSettings
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isDarkMode = SystemToggles.isDarkMode
    @Published var keepAwake = false
    @Published var nightShiftAvailable = false
    @Published var trueToneAvailable = false
    @Published var nightShiftOn = false
    @Published var trueToneOn = false
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var accessibilityTrusted = AXIsProcessTrusted()
    @Published var isRefreshing = false
    @Published var settingsPresented = false

    let runtime: NitsRuntime
    private let mediaKeys = MediaKeyTap()
    private var observer: NSObjectProtocol?
    private var messageWork: DispatchWorkItem?
    private var refreshTask: Task<Void, Never>?
    private var refreshedControls: Set<String> = []

    init(runtime: NitsRuntime) {
        self.runtime = runtime
        self.settings = runtime.config.snapshot().general
        self.keepAwake = runtime.keepAwake.isActive
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: .nitsDisplaysDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll(seedHardware: false)
            }
        }

        runtime.hotkeys.setHandler { [weak self] action in
            Task { @MainActor in self?.performHotkey(action) }
        }
        runtime.syncHotkeys()

        mediaKeys.handler = { [weak self] key in
            Task { @MainActor in self?.handleMediaKey(key) }
        }
        if settings.mediaKeysEnabled {
            if MediaKeyTap.isTrusted {
                _ = mediaKeys.start()
            } else {
                // Never prompt for Accessibility just because the app launched; the
                // user turns media keys on deliberately in Settings.
                runtime.updateGeneral { $0.mediaKeysEnabled = false }
                settings = runtime.config.snapshot().general
            }
        }
        refreshScreenEffects()
        refreshAll(seedHardware: true)
    }

    func refreshScreenEffects() {
        nightShiftAvailable = runtime.coreBrightness.nightShiftAvailable
        trueToneAvailable = runtime.coreBrightness.trueToneAvailable
        nightShiftOn = runtime.nightShiftEnabled()
        trueToneOn = runtime.trueToneEnabled()
    }

    func setNightShift(_ on: Bool) {
        guard runtime.setNightShift(on) else {
            showError("Night Shift is not available on this Mac")
            refreshScreenEffects()
            return
        }
        nightShiftOn = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshScreenEffects()
        }
    }

    func setTrueTone(_ on: Bool) {
        guard runtime.setTrueTone(on) else {
            showError("True Tone is not available on this Mac")
            refreshScreenEffects()
            return
        }
        trueToneOn = on
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshScreenEffects()
        }
    }

    func stopMediaKeys() {
        mediaKeys.stop()
    }

    // MARK: - Refresh

    /// Called after the CLI changes the shared config file.
    func reloadFromDisk() {
        if runtime.config.reloadIfChanged() {
            presets = runtime.presets.presets()
            settings = runtime.config.snapshot().general
            runtime.syncHotkeys()
        }
        refreshAll(seedHardware: false)
    }

    func refreshAll(seedHardware: Bool) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            let states = await self.runtime.states(refresh: seedHardware)
            self.merge(states)
            self.disconnected = self.runtime.disconnectedDisplays()
            self.presets = self.runtime.presets.presets()
            self.virtualConfigs = self.runtime.virtualDisplays.configs
            self.groups = self.runtime.groups()
            self.settings = self.runtime.config.snapshot().general
            self.isRefreshing = false
            self.refreshTask = nil

            for row in self.rows where row.brightness == nil || row.volume == nil {
                self.refreshControls(rowID: row.id, quiet: true)
            }
        }
    }

    private func merge(_ states: [DisplayState]) {
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = states.map { state in
            let old = existing[state.display.uuid]
            var row = DisplayRowState(
                state: state,
                brightness: state.brightness ?? old?.brightness,
                volume: state.volume ?? old?.volume,
                contrast: old?.contrast,
                gamma: state.gamma,
                inputs: old?.inputs,
                currentInput: old?.currentInput,
                profiles: old?.profiles,
                currentProfileName: old?.currentProfileName ?? runtime.currentProfileName(for: state.display)
            )
            row.isExpanded = old?.isExpanded
                ?? (ProcessInfo.processInfo.environment["NITS_EXPAND_ALL"] == "1")
            return row
        }
    }

    func refreshControls(rowID: String, quiet: Bool = false) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let state = await self.runtime.state(for: display, refresh: true)
            guard let current = self.rows.firstIndex(where: { $0.id == rowID }) else { return }
            self.rows[current].state = state
            if let brightness = state.brightness { self.rows[current].brightness = brightness }
            if let volume = state.volume { self.rows[current].volume = volume }
            if !quiet { self.showStatus("Refreshed \(display.name)") }
        }
    }

    func loadInputs(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              !rows[index].inputsLoading
        else { return }
        let display = rows[index].display
        rows[index].inputsLoading = true
        Task { [weak self] in
            guard let self else { return }
            let options = await self.runtime.inputOptions(for: display)
            let current = await self.runtime.input.currentInput(for: display)
            guard let currentIndex = self.rows.firstIndex(where: { $0.id == rowID }) else { return }
            self.rows[currentIndex].inputs = options
            self.rows[currentIndex].currentInput = current
            self.rows[currentIndex].inputsLoading = false
        }
    }

    // MARK: - Brightness / volume / image

    func setBrightness(_ value: Double, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].brightness = value
        let display = rows[index].display
        Task { [weak self] in
            _ = await self?.runtime.setBrightness(value, for: display)
        }
    }

    func setVolume(_ value: Double, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].volume = value
        let display = rows[index].display
        Task { [weak self] in
            _ = await self?.runtime.setVolume(value, for: display)
        }
    }

    func setContrast(_ value: Double, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].contrast = value
        let display = rows[index].display
        Task { [weak self] in
            _ = await self?.runtime.setContrast(value, for: display)
        }
    }

    func modifyGamma(rowID: String, _ mutate: (inout GammaAdjustment) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        var adjustment = rows[index].gamma
        mutate(&adjustment)
        rows[index].gamma = adjustment
        let display = rows[index].display
        runtime.setGamma(adjustment, for: display)
    }

    func resetGamma(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].gamma = GammaAdjustment()
        runtime.setGamma(GammaAdjustment(), for: rows[index].display)
    }

    func toggleHDRSoftware(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let on = !rows[index].state.hdrSoftware
        rows[index].state.hdrSoftware = on
        runtime.setHDRSoftwareDimming(on, for: rows[index].display)
    }

    func toggleExtraBrightness(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let on = !rows[index].state.extraBrightness
        rows[index].state.extraBrightness = on
        runtime.setExtraBrightness(on, for: rows[index].display)
        showStatus("Extra brightness \(on ? "on" : "off") — panels can run hot")
    }

    // MARK: - Modes and arrangement

    func setMode(_ mode: DisplayModeInfo, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        rows[index].isBusy = true
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.setMode(
                width: mode.width,
                height: mode.height,
                refresh: mode.refreshRate,
                hiDPI: mode.isHiDPI,
                for: display
            )
            if let current = self.rows.firstIndex(where: { $0.id == rowID }) {
                self.rows[current].isBusy = false
            }
            if ok {
                self.showStatus("\(display.name): \(mode.label)")
                self.refreshAll(seedHardware: false)
            } else {
                self.showError("Could not switch \(display.name) to \(mode.label)")
            }
        }
    }

    func setDefaultResolution(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        runtime.setCurrentModeAsDefault(for: rows[index].display)
        showStatus("Current resolution saved as default")
    }

    func clearDefaultResolution(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        runtime.clearDefaultMode(for: rows[index].display)
        showStatus("Default resolution cleared")
    }

    func toggleHiDPI(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        rows[index].isBusy = true
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.toggleHiDPI(for: display)
            if let current = self.rows.firstIndex(where: { $0.id == rowID }) {
                self.rows[current].isBusy = false
            }
            if ok { self.refreshAll(seedHardware: false) }
            else { self.showError("No HiDPI twin at this size on \(display.name)") }
        }
    }

    func rename(rowID: String, name: String?) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        runtime.setDisplayName(name, for: display)
        refreshAll(seedHardware: false)
    }

    func applyArrangement(_ positions: [UInt32: CGPoint]) async -> Bool {
        let mapped = positions.mapValues { ArrangementPosition(x: $0.x, y: $0.y) }
        let ok = await runtime.arrangement.setPositions(mapped)
        if ok {
            refreshAll(seedHardware: false)
        }
        return ok
    }

    func setMain(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.setMain(display)
            if ok { self.refreshAll(seedHardware: false) }
            else { self.showError("Could not make \(display.name) main") }
        }
    }

    func rotate(rowID: String, degrees: Int) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.rotate(display, degrees: degrees)
            if ok { self.refreshAll(seedHardware: false) }
            else { self.showError("Rotation failed on \(display.name)") }
        }
    }

    func enableHiDPI(rowID: String, dense: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        rows[index].isBusy = true
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runtime.enableHiDPI(display, dense: dense)
            if let current = self.rows.firstIndex(where: { $0.id == rowID }) {
                self.rows[current].isBusy = false
            }
            if result.succeeded {
                self.showStatus("HiDPI modes installed. Reconnect if they do not appear.")
                self.refreshAll(seedHardware: false)
            } else {
                self.showError(result.message ?? "HiDPI install failed")
            }
        }
    }

    func disableHiDPI(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runtime.disableHiDPI(display)
            if !result.succeeded { self.showError(result.message ?? "Could not remove override") }
            self.refreshAll(seedHardware: false)
        }
    }

    // MARK: - Color profiles

    func loadColorProfiles(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              rows[index].profiles == nil
        else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let profiles = await self.runtime.profiles(for: display)
            let current = self.runtime.currentProfileName(for: display)
            guard let currentIndex = self.rows.firstIndex(where: { $0.id == rowID }) else { return }
            self.rows[currentIndex].profiles = profiles
            self.rows[currentIndex].currentProfileName = current
        }
    }

    func setColorProfile(_ profile: ICCProfile, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        let ok = runtime.setProfile(profile, for: display)
        if ok {
            rows[index].currentProfileName = profile.name
            showStatus("\(display.name): \(profile.name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.refreshColorProfileName(rowID: rowID)
            }
        } else {
            showError("Could not assign \(profile.name)")
        }
    }

    private func refreshColorProfileName(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        rows[index].currentProfileName = runtime.currentProfileName(for: display)
    }

    // MARK: - Inputs

    func setInput(_ value: UInt16, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        rows[index].currentInput = value
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.setInput(value, for: display)
            if !ok { self.showError("Input switch failed on \(display.name)") }
            self.loadInputs(rowID: rowID)
        }
    }

    // MARK: - Toggles and connection

    func toggleExpanded(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[index].isExpanded.toggle()
        if rows[index].isExpanded {
            loadInputs(rowID: rowID)
            loadColorProfiles(rowID: rowID)
            if rows[index].contrast == nil {
                let display = rows[index].display
                Task { [weak self] in
                    guard let self else { return }
                    let value = await self.runtime.hardware.readContrast(for: display)
                    if let current = self.rows.firstIndex(where: { $0.id == rowID }) {
                        self.rows[current].contrast = value
                    }
                }
            }
        }
    }

    func disconnect(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        let display = rows[index].display
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runtime.disconnect(display)
            switch result {
            case .success:
                self.showStatus("Disconnected \(display.name)")
            case .failure(let error):
                self.showError(error.description)
            }
            self.refreshAll(seedHardware: false)
        }
    }

    func reconnect(_ record: DisconnectedDisplay) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runtime.reconnect(uuid: record.uuid)
            if case .failure(let error) = result {
                self.showError(error.description)
            }
            self.refreshAll(seedHardware: true)
        }
    }

    // MARK: - Display groups

    func saveGroup(_ group: DisplayGroup) {
        runtime.saveGroup(group)
        groups = runtime.groups()
        showStatus("Saved group \(group.name)")
    }

    func deleteGroup(id: UUID) {
        runtime.deleteGroup(id: id)
        groups = runtime.groups()
    }

    // MARK: - Virtual displays

    func createVirtualDisplay(_ configuration: VirtualDisplayConfig) {
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.runtime.virtualDisplays.add(configuration)
            if ok {
                self.showStatus("Created \(configuration.name)")
            } else {
                self.showError("Could not create the virtual display")
            }
            self.virtualConfigs = self.runtime.virtualDisplays.configs
            self.refreshAll(seedHardware: false)
        }
    }

    func removeVirtualDisplay(id: UUID) {
        runtime.virtualDisplays.remove(id: id)
        virtualConfigs = runtime.virtualDisplays.configs
        refreshAll(seedHardware: false)
    }

    func setVirtualAutoCreate(_ on: Bool, id: UUID) {
        runtime.virtualDisplays.setAutoCreate(on, id: id)
        virtualConfigs = runtime.virtualDisplays.configs
    }

    // MARK: - Presets

    func savePreset(name: String, icon: String, hotkey: HotkeyBinding?) {
        Task { [weak self] in
            guard let self else { return }
            guard let captured = await self.runtime.presets.capture(name: name, icon: icon) else {
                self.showError("Could not capture the current setup")
                return
            }
            var preset = captured
            preset.hotkey = hotkey
            _ = self.runtime.presets.save(preset)
            self.runtime.syncHotkeys()
            self.presets = self.runtime.presets.presets()
            self.showStatus("Saved preset \(name)")
        }
    }

    func applyPreset(id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runtime.presets.apply(preset)
            if !result.errors.isEmpty {
                self.showError(result.errors.joined(separator: "; "))
            } else {
                self.showStatus("Applied \(preset.name)")
            }
            self.refreshAll(seedHardware: true)
        }
    }

    func deletePreset(id: UUID) {
        runtime.presets.delete(id: id)
        runtime.syncHotkeys()
        presets = runtime.presets.presets()
    }

    func setPresetHotkey(id: UUID, binding: HotkeyBinding?) {
        guard var preset = runtime.presets.presets().first(where: { $0.id == id }) else { return }
        preset.hotkey = binding
        _ = runtime.presets.save(preset)
        runtime.syncHotkeys()
        presets = runtime.presets.presets()
    }

    // MARK: - Hotkeys and media keys

    func performHotkey(_ action: HotkeyAction) {
        guard let display = targetDisplay() else { return }
        let general = settings
        Task { [weak self] in
            guard let self else { return }
            switch action {
            case .brightnessUp:
                let value = await self.runtime.adjustBrightness(by: general.brightnessStep, for: display)
                self.showBrightnessOSD(value, display: display)
            case .brightnessDown:
                let value = await self.runtime.adjustBrightness(by: -general.brightnessStep, for: display)
                self.showBrightnessOSD(value, display: display)
            case .volumeUp:
                let value = await self.runtime.adjustVolume(by: general.volumeStep, for: display)
                self.showVolumeOSD(value, display: display)
            case .volumeDown:
                let value = await self.runtime.adjustVolume(by: -general.volumeStep, for: display)
                self.showVolumeOSD(value, display: display)
            case .toggleMute:
                _ = await self.runtime.toggleMute(for: display)
                self.showStatus("\(display.name): mute toggled")
            case .toggleHiDPI:
                _ = await self.runtime.toggleHiDPI(for: display)
            case .cycleInput:
                let options = await self.runtime.inputOptions(for: display)
                guard options.count > 1 else { return }
                let current = await self.runtime.input.currentInput(for: display)
                let index = options.firstIndex { $0.value == current } ?? -1
                let next = options[(index + 1) % options.count]
                _ = await self.runtime.setInput(next.value, for: display)
                self.showStatus("\(display.name): \(next.name)")
            case .preset(let id):
                self.applyPreset(id: id)
            }
        }
    }

    private func handleMediaKey(_ key: MediaKeyTap.Key) {
        switch key {
        case .brightnessUp:
            performHotkey(.brightnessUp)
        case .brightnessDown:
            performHotkey(.brightnessDown)
        case .soundUp:
            performHotkey(.volumeUp)
        case .soundDown:
            performHotkey(.volumeDown)
        case .mute:
            performHotkey(.toggleMute)
        }
    }

    private func showBrightnessOSD(_ value: Double?, display: DisplaySnapshot) {
        guard settings.showOSD, let value else { return }
        let fraction = min(1, max(0, value / 100))
        let nits = display.nominalMaxNits.map {
            " · ~\(Int((value / 100 * $0).rounded())) nits"
        } ?? ""
        OSDController.shared.show(
            icon: value > 100 ? "sun.max.trianglebadge.exclamationmark.fill" : "sun.max.fill",
            title: value > 100 ? "Extra Brightness" : "Brightness",
            detail: "\(Int(value.rounded()))%\(nits)",
            fraction: fraction,
            duration: settings.osdDuration
        )
    }

    private func showVolumeOSD(_ value: Double?, display: DisplaySnapshot) {
        guard settings.showOSD, let value else { return }
        OSDController.shared.show(
            icon: "speaker.wave.2.fill",
            title: display.name,
            detail: "\(Int(value.rounded()))%",
            fraction: min(1, max(0, value / 100)),
            duration: settings.osdDuration
        )
    }

    func setMediaKeys(_ enabled: Bool) {
        if enabled {
            guard startMediaKeys() else {
                showError("Media keys need Accessibility permission (System Settings → Privacy & Security → Accessibility).")
                runtime.updateGeneral { $0.mediaKeysEnabled = false }
                settings = runtime.config.snapshot().general
                return
            }
        } else {
            mediaKeys.stop()
        }
        runtime.updateGeneral { $0.mediaKeysEnabled = enabled }
        settings = runtime.config.snapshot().general
    }

    private func startMediaKeys() -> Bool {
        if MediaKeyTap.isTrusted {
            return mediaKeys.start()
        }
        _ = MediaKeyTap.requestTrust()
        accessibilityTrusted = AXIsProcessTrusted()
        return false
    }

    func requestAccessibility() {
        _ = MediaKeyTap.requestTrust()
        accessibilityTrusted = AXIsProcessTrusted()
    }

    // MARK: - System

    func setKeepAwake(_ on: Bool) {
        if runtime.setKeepAwake(on) {
            keepAwake = on
            settings = runtime.config.snapshot().general
        }
    }

    func toggleDarkMode() {
        if let result = SystemToggles.toggleDarkMode() {
            isDarkMode = result
        } else {
            showError("Dark Mode needs Automation permission for System Events.")
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        _ = LaunchAtLogin.setEnabled(on)
        launchAtLogin = LaunchAtLogin.isEnabled
        runtime.updateGeneral { $0.launchAtLogin = on }
        settings = runtime.config.snapshot().general
    }

    func updateGeneral(_ mutate: (inout GeneralSettings) -> Void) {
        runtime.updateGeneral(mutate)
        settings = runtime.config.snapshot().general
    }

    // MARK: - Helpers

    func display(matching term: String?) -> DisplaySnapshot? {
        DisplaySelector.match(term, in: rows.map(\.display))
    }

    func targetDisplay() -> DisplaySnapshot? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }), let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let display = rows.first(where: { $0.display.id == id })?.display {
            return display
        }
        return rows.first(where: { $0.display.isMain })?.display ?? rows.first?.display
    }

    func showStatus(_ message: String) {
        statusMessage = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func showError(_ message: String) {
        errorMessage = message
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.errorMessage = nil }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

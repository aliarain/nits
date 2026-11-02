import Foundation
import CoreGraphics

/// Captures and applies named display configurations. Persistence lives in ConfigStore;
/// the engine only knows how to translate a preset into calls on the runtime.
public final class PresetEngine: @unchecked Sendable {
    private let config: ConfigStore
    private weak var runtime: NitsRuntime?

    public init(config: ConfigStore) {
        self.config = config
    }

    public func attach(_ runtime: NitsRuntime) {
        self.runtime = runtime
    }

    // MARK: - CRUD

    public func presets() -> [DisplayPreset] {
        config.snapshot().presets.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func save(_ preset: DisplayPreset) -> DisplayPreset {
        var saved = preset
        config.update { config in
            if let index = config.presets.firstIndex(where: { $0.id == saved.id }) {
                config.presets[index] = saved
            } else {
                config.presets.append(saved)
            }
        }
        // Keep the in-memory copy in sync with the stored revision.
        if let stored = config.snapshot().presets.first(where: { $0.id == saved.id }) {
            saved = stored
        }
        return saved
    }

    public func delete(id: UUID) {
        config.update { config in
            config.presets.removeAll { $0.id == id }
        }
    }

    public func preset(named name: String) -> DisplayPreset? {
        presets().first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            ?? presets().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    // MARK: - Capture

    public func capture(name: String, icon: String = "display") async -> DisplayPreset? {
        guard let runtime else { return nil }
        let states = await runtime.states(refresh: true)
        var entries: [DisplayPresetEntry] = []

        for state in states {
            let display = state.display
            var entry = DisplayPresetEntry(
                displayUUID: display.uuid,
                mode: state.currentMode.map(ModeSpec.init(mode:)),
                brightness: state.brightness,
                gamma: state.gamma.isNeutral ? nil : state.gamma,
                position: ArrangementPosition(x: display.bounds.x, y: display.bounds.y),
                connected: true,
                hdrSoftware: state.hdrSoftware
            )
            if !display.isBuiltin {
                entry.volume = runtime.volume.lastPercent(for: display.id)
                entry.contrast = await runtime.hardware.readContrast(for: display)
                entry.input = await runtime.input.currentInput(for: display)
            }
            entries.append(entry)
        }

        for record in runtime.disconnect.disconnectedDisplays() {
            entries.append(DisplayPresetEntry(displayUUID: record.uuid, connected: false))
        }

        guard !entries.isEmpty else { return nil }
        return DisplayPreset(name: name, icon: icon, entries: entries)
    }

    // MARK: - Apply

    public func apply(_ preset: DisplayPreset) async -> PresetApplyResult {
        var result = PresetApplyResult()
        guard let runtime else {
            result.errors.append("runtime unavailable")
            return result
        }

        var displays = runtime.displays()
        let byUUID = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0) })
        let disconnected = Dictionary(
            uniqueKeysWithValues: runtime.disconnect.disconnectedDisplays().map { ($0.uuid, $0) }
        )

        // Connection changes first: their configuration transaction moves the other
        // displays' modes, so every later setting must land after it.
        var reconnected = false
        for entry in preset.entries {
            if entry.connected == false, let display = byUUID[entry.displayUUID] {
                let outcome = await runtime.disconnect(display)
                if case .failure(let error) = outcome {
                    result.errors.append("\(display.name): \(error.description)")
                }
            } else if entry.connected == true, let record = disconnected[entry.displayUUID] {
                let outcome = await runtime.reconnect(uuid: record.uuid)
                if case .failure(let error) = outcome {
                    result.errors.append("\(record.name): \(error.description)")
                } else {
                    reconnected = true
                }
            }
        }
        if reconnected {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            displays = runtime.displays()
        }

        let online = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0) })

        // Layout in one transaction.
        var positions: [CGDirectDisplayID: ArrangementPosition] = [:]
        for entry in preset.entries {
            guard let position = entry.position, let display = online[entry.displayUUID] else { continue }
            positions[display.id] = position
        }
        if !positions.isEmpty {
            if !(await runtime.arrangement.setPositions(positions)) {
                result.errors.append("arrangement change failed")
            }
        }

        for entry in preset.entries {
            guard let display = online[entry.displayUUID] else {
                if entry.connected != true { result.skipped.append(entry.displayUUID) }
                continue
            }
            var failure: String?

            if let mode = entry.mode {
                let ok = await runtime.setMode(
                    width: mode.width,
                    height: mode.height,
                    refresh: mode.refreshRate,
                    hiDPI: mode.hiDPI,
                    for: display
                )
                if !ok { failure = "resolution \(mode.label)" }
            }
            if let brightness = entry.brightness {
                _ = await runtime.setBrightness(brightness, for: display, wait: true)
            }
            if let volume = entry.volume, !display.isBuiltin {
                _ = await runtime.setVolume(volume, for: display, wait: true)
            }
            if let contrast = entry.contrast, !display.isBuiltin {
                _ = await runtime.setContrast(contrast, for: display, wait: true)
            }
            if let input = entry.input, !display.isBuiltin {
                _ = await runtime.setInput(input, for: display)
            }
            if let hdr = entry.hdrSoftware {
                runtime.setHDRSoftwareDimming(hdr, for: display)
            }
            if let gamma = entry.gamma {
                runtime.setGamma(gamma, for: display)
            }

            if let failure {
                result.errors.append("\(display.name): \(failure)")
            } else {
                result.applied.append(display.name)
            }
        }

        NitsLog.preset.notice("preset \(preset.name, privacy: .public): \(result.summary, privacy: .public)")
        return result
    }
}

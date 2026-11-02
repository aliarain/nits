import Foundation
import NitsCore

enum CLIError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

enum NitsCLI {
    static func run(arguments: [String]) async -> Int32 {
        var options = Options()
        do {
            var positionals = try options.parse(arguments)
            guard let command = positionals.first else {
                printHelp()
                return 0
            }
            positionals.removeFirst()

            if command == "help" || command == "--help" || command == "-h" {
                printHelp()
                return 0
            }
            if command == "version" || command == "--version" {
                print("Nits \(NitsVersion.current)")
                return 0
            }

            let runtime = NitsRuntime(configURL: options.configURL)
            try await dispatch(command: command, args: positionals, options: options, runtime: runtime)
            // Persist this command's local changes first. Only when there are none (for
            // example a virtual display created by the running app) load what the app
            // wrote, so a delegated command's result is not overwritten.
            if runtime.config.hasUnsavedChanges {
                runtime.config.save()
            } else {
                runtime.config.reloadIfChanged()
                runtime.config.save()
            }
            // Keep a running app's UI, presets and hotkeys in step with CLI changes.
            if !["watch", "doctor", "list", "ls", "get", "version"].contains(command) {
                _ = ControlClient.send("reload", timeout: 1.0)
            }
            return 0
        } catch let error as CLIError {
            fail(error.description)
            return 1
        } catch let error as DisconnectError {
            fail(error.description)
            return 1
        } catch {
            fail(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Dispatch

    private static func dispatch(
        command: String,
        args: [String],
        options: Options,
        runtime: NitsRuntime
    ) async throws {
        switch command {
        case "list", "ls":
            try await list(runtime: runtime, json: options.json)
        case "get":
            try await getVCP(args: args, options: options, runtime: runtime)
        case "set":
            try await setVCP(args: args, options: options, runtime: runtime)
        case "brightness", "b":
            try await brightness(args: args, options: options, runtime: runtime)
        case "volume", "v":
            try await volume(args: args, options: options, runtime: runtime)
        case "contrast":
            try await contrast(args: args, options: options, runtime: runtime)
        case "mute":
            try await mute(options: options, runtime: runtime)
        case "input":
            try await input(args: args, options: options, runtime: runtime)
        case "mode", "resolution":
            try await mode(args: args, options: options, runtime: runtime)
        case "rotate":
            try await rotate(args: args, options: options, runtime: runtime)
        case "main":
            try await mainDisplay(options: options, runtime: runtime)
        case "mirror":
            try await mirror(args: args, options: options, runtime: runtime)
        case "unmirror":
            try await unmirror(options: options, runtime: runtime)
        case "preset", "presets":
            try await preset(args: args, options: options, runtime: runtime)
        case "disconnect":
            try await disconnect(options: options, runtime: runtime)
        case "reconnect":
            try await reconnect(args: args, options: options, runtime: runtime)
        case "rename":
            try rename(args: args, options: options, runtime: runtime)
        case "edid":
            try await edid(args: args, options: options, runtime: runtime)
        case "hidpi":
            try await hidpi(args: args, options: options, runtime: runtime)
        case "profile", "colorprofile", "color-profile":
            try await colorProfile(args: args, options: options, runtime: runtime)
        case "virtual":
            try await virtual(args: args, options: options, runtime: runtime)
        case "action", "actions":
            try eventActions(args: args, options: options, runtime: runtime)
        case "group", "groups":
            try await groups(args: args, options: options, runtime: runtime)
        case "gamma", "image":
            try await gamma(args: args, options: options, runtime: runtime)
        case "hdr":
            try await hdr(args: args, options: options, runtime: runtime)
        case "extra":
            try await extra(args: args, options: options, runtime: runtime)
        case "sync":
            try await sync(args: args, options: options, runtime: runtime)
        case "system":
            try await system(args: args, options: options, runtime: runtime)
        case "config":
            configCommand(args: args, runtime: runtime)
        case "doctor":
            try await doctor(runtime: runtime, json: options.json)
        case "watch":
            try await watch(options: options, runtime: runtime)
        default:
            throw CLIError.message("Unknown command '\(command)'. Run `nitsctl help`.")
        }
    }

    // MARK: - Listing

    private static func list(runtime: NitsRuntime, json: Bool) async throws {
        let states = await runtime.states(refresh: false)
        guard !states.isEmpty else { throw CLIError.message("No displays") }
        if json {
            print(try encode(states))
            return
        }
        print("Nits \(NitsVersion.current)")
        for state in states {
            let display = state.display
            let marker = display.isMain ? "*" : " "
            let brightness = state.brightness.map { String(format: "%.0f%%", $0) } ?? "?"
            let volume = state.volume.map { String(format: "%.0f%%", $0) } ?? "—"
            let mode = state.currentMode.map { "\($0.width)×\($0.height)\($0.isHiDPI ? " HiDPI" : "") @\(Int($0.refreshRate))Hz" } ?? "?"
            print("\(marker) \(display.id)\t\(display.name)\t\(mode)\tbrightness \(brightness) (\(state.backend.rawValue))\tvolume \(volume)\(state.disconnected ? "\tdisconnected" : "")")
        }
        let disconnected = runtime.disconnectedDisplays()
        if !disconnected.isEmpty {
            print("Disconnected: \(disconnected.map { "\($0.name) [\($0.uuid)]" }.joined(separator: ", "))")
        }
    }

    // MARK: - Raw DDC

    private static func getVCP(args: [String], options: Options, runtime: NitsRuntime) async throws {
        guard let codeText = args.first else { throw CLIError.message("Usage: nitsctl get <vcpCode> [--display]") }
        guard let code = parseVCPCode(codeText) else { throw CLIError.message("Invalid VCP code '\(codeText)'") }
        let display = try resolveDisplay(options: options, runtime: runtime)
        let value = await runtime.ddc.read(display: display, code: code, useCache: false)
        guard let value else { throw CLIError.message("No valid reply for VCP \(codeText) on \(display.name)") }
        if options.json {
            print(try encode(["display": display.name, "vcp": String(format: "0x%02X", code), "current": value.current, "max": value.max] as [String: Any]))
        } else {
            print("\(display.name) VCP \(String(format: "0x%02X", code)): \(value.current)/\(value.max)")
        }
    }

    private static func setVCP(args: [String], options: Options, runtime: NitsRuntime) async throws {
        guard args.count >= 2 else { throw CLIError.message("Usage: nitsctl set <vcpCode> <value> [--display]") }
        guard let code = parseVCPCode(args[0]) else {
            throw CLIError.message("Invalid VCP code '\(args[0])'")
        }
        let value = try parseUInt16(args[1])
        let display = try resolveDisplay(options: options, runtime: runtime)
        let ok = await runtime.ddc.write(display: display, code: code, value: value)
        guard ok else { throw CLIError.message("Write failed on \(display.name)") }
        print("Set VCP \(String(format: "0x%02X", code))=\(value) on \(display.name)")
    }

    // MARK: - Controls

    private static func brightness(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let displays = try resolveDisplays(options: options, runtime: runtime)
        if let term = args.first {
            let delta = parseDelta(term)
            for display in displays {
                if let delta {
                    let current = (await runtime.state(for: display, refresh: true)).brightness ?? 50
                    let target = min(150, max(0, current + delta))
                    let ok = await runtime.setBrightness(target, for: display, wait: true)
                    print("\(display.name): \(String(format: "%.1f%%", target))\(ok == false ? " (write failed)" : "")")
                } else {
                    let value = try parseDouble(term, name: "brightness")
                    let ok = await runtime.setBrightness(value, for: display, wait: true)
                    print("\(display.name): \(String(format: "%.1f%%", value))\(ok == false ? " (write failed)" : "")")
                }
            }
            return
        }
        for display in displays {
            let state = await runtime.state(for: display, refresh: true)
            if options.json {
                print(try encode(state))
            } else {
                print("\(display.name): \(state.brightness.map { String(format: "%.1f%%", $0) } ?? "unknown") backend=\(state.backend.rawValue)")
            }
        }
    }

    private static func volume(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let displays = try resolveDisplays(options: options, runtime: runtime)
        if let term = args.first {
            let delta = parseDelta(term)
            for display in displays where !display.isBuiltin {
                if let delta {
                    let current = (await runtime.state(for: display, refresh: true)).volume ?? 50
                    let target = min(100, max(0, current + delta))
                    let ok = await runtime.setVolume(target, for: display, wait: true)
                    print("\(display.name): \(String(format: "%.1f%%", target))\(ok == false ? " (write failed)" : "")")
                } else {
                    let value = try parseDouble(term, name: "volume")
                    let ok = await runtime.setVolume(value, for: display, wait: true)
                    print("\(display.name): \(String(format: "%.1f%%", value))\(ok == false ? " (write failed)" : "")")
                }
            }
            return
        }
        for display in displays {
            let state = await runtime.state(for: display, refresh: true)
            if options.json {
                print(try encode(state))
            } else {
                let supported = state.volumeSupported == true ? "" : " (not supported)"
                print("\(display.name): \(state.volume.map { String(format: "%.1f%%", $0) } ?? "unknown")\(supported)")
            }
        }
    }

    private static func contrast(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let displays = try resolveDisplays(options: options, runtime: runtime)
        if let term = args.first {
            let value = try parseDouble(term, name: "contrast")
            for display in displays where !display.isBuiltin {
                let ok = await runtime.setContrast(value, for: display, wait: true)
                print("\(display.name): \(ok == true ? "set" : "failed")")
            }
            return
        }
        for display in displays where !display.isBuiltin {
            let value = await runtime.hardware.readContrast(for: display)
            print("\(display.name): \(value.map { String(format: "%.1f%%", $0) } ?? "unknown")")
        }
    }

    private static func mute(options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let ok = await runtime.toggleMute(for: display)
        print("\(display.name): \(ok ? "toggled mute" : "mute failed")")
    }

    private static func input(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let displays = try resolveDisplays(options: options, runtime: runtime)
        for display in displays where !display.isBuiltin {
            if args.first == "list" || args.isEmpty {
                let current = await runtime.input.currentInput(for: display)
                let choices = await runtime.inputOptions(for: display)
                print("\(display.name) current: \(current.map { formatInput($0) } ?? "unknown")")
                for choice in choices {
                    let marker = choice.value == current ? "*" : " "
                    print(" \(marker) \(choice.name) (\(String(format: "0x%02X", choice.value)))")
                }
                if args.isEmpty { continue }
            }
            if let term = args.first, term != "list" {
                guard let value = InputSource.value(from: term) else {
                    throw CLIError.message("Unknown input '\(term)'. Try `nitsctl input list`.")
                }
                let ok = await runtime.setInput(value, for: display)
                print("\(display.name): \(ok ? "switched to \(formatInput(value))" : "switch failed")")
            }
        }
    }

    // MARK: - Modes

    private static func mode(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        guard let subcommand = args.first else {
            try await listModes(display: display, options: options, runtime: runtime)
            return
        }
        switch subcommand {
        case "list", "ls":
            try await listModes(display: display, options: options, runtime: runtime)
        case "set":
            guard args.count >= 2 else { throw CLIError.message("Usage: nitsctl mode set 2560x1440[@120] [hidpi]") }
            let spec = try parseModeSpec(args[1], hiDPIFlag: args.dropFirst(2).contains("hidpi"))
            let ok = await runtime.setMode(
                width: spec.width,
                height: spec.height,
                refresh: spec.refreshRate,
                hiDPI: spec.hiDPI,
                for: display
            )
            print("\(display.name): \(ok ? "mode set" : "mode change failed")")
        case "scale":
            try await scaleMode(args: Array(args.dropFirst()), display: display, options: options, runtime: runtime)
        case "hidpi", "toggle":
            let ok = await runtime.toggleHiDPI(for: display)
            print("\(display.name): \(ok ? "HiDPI toggled" : "no HiDPI twin at this size")")
        default:
            let spec = try parseModeSpec(subcommand, hiDPIFlag: args.dropFirst().contains("hidpi"))
            let ok = await runtime.setMode(
                width: spec.width,
                height: spec.height,
                refresh: spec.refreshRate,
                hiDPI: spec.hiDPI,
                for: display
            )
            print("\(display.name): \(ok ? "mode set" : "mode change failed")")
        }
    }

    private static func scaleMode(
        args: [String],
        display: DisplaySnapshot,
        options: Options,
        runtime: NitsRuntime
    ) async throws {
        guard let (ladder, index) = runtime.scaleLadder(for: display) else {
            throw CLIError.message("\(display.name): no scale ladder for the current mode")
        }
        let usage = "Usage: nitsctl mode scale [list|up|down|<index>]"
        switch args.first ?? "list" {
        case "list", "ls":
            if options.json {
                print(try encode(ladder))
                return
            }
            print("\(display.name) scale (larger text → more space):")
            for (offset, mode) in ladder.enumerated() {
                print("\(offset == index ? "*" : " ") \(offset): \(mode.width)×\(mode.height)")
            }
        case "up", "down":
            let ok = await runtime.stepScale(by: args[0] == "up" ? 1 : -1, for: display)
            print("\(display.name): \(ok ? "scale changed" : "already at the end of the scale")")
        case let value:
            guard let target = Int(value), ladder.indices.contains(target) else { throw CLIError.message(usage) }
            let ok = target == index ? true : await runtime.setScale(ladder[target], for: display)
            print("\(display.name): \(ok ? "scale set to \(ladder[target].width)×\(ladder[target].height)" : "scale change failed")")
        }
    }

    private static func listModes(display: DisplaySnapshot, options: Options, runtime: NitsRuntime) async throws {
        let modes = runtime.resolution.modes(for: display.id)
        let current = runtime.resolution.currentMode(for: display.id)
        if options.json {
            print(try encode(modes))
            return
        }
        print("\(display.name) modes (\(modes.count)):")
        for mode in modes {
            let marker = mode.id == current?.id ? "*" : " "
            print("\(marker) \(mode.label)")
        }
    }

    private static func rotate(args: [String], options: Options, runtime: NitsRuntime) async throws {
        guard let degrees = args.first.flatMap(Int.init), [0, 90, 180, 270].contains(degrees) else {
            throw CLIError.message("Usage: nitsctl rotate 0|90|180|270 [--display]")
        }
        let display = try resolveDisplay(options: options, runtime: runtime)
        let ok = await runtime.rotate(display, degrees: degrees)
        print("\(display.name): \(ok ? "rotated \(degrees)°" : "rotation failed")")
    }

    private static func mainDisplay(options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let ok = await runtime.setMain(display)
        print("\(display.name): \(ok ? "is now main" : "could not set main")")
    }

    private static func mirror(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let target = try resolveDisplay(options: options, runtime: runtime)
        let source: DisplaySnapshot
        if let onto = options.onto {
            guard let match = runtime.display(matching: onto) else {
                throw CLIError.message("No display matching '\(onto)'")
            }
            source = match
        } else {
            guard let other = runtime.displays().first(where: { $0.id != target.id }) else {
                throw CLIError.message("A mirror needs two displays")
            }
            source = other
        }
        let ok = await runtime.mirror(target, onto: source)
        print("\(target.name): \(ok ? "mirroring \(source.name)" : "mirror failed")")
    }

    private static func unmirror(options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let ok = await runtime.unmirror(display)
        print("\(display.name): \(ok ? "unmirrored" : "unmirror failed")")
    }

    // MARK: - Presets

    private static func preset(args: [String], options: Options, runtime: NitsRuntime) async throws {
        guard let subcommand = args.first else {
            for preset in runtime.presets.presets() {
                print("\(preset.name)\t\(preset.id.uuidString)\t\(preset.entries.count) display(s)\(preset.hotkey.map { " · \($0.label)" } ?? "")")
            }
            return
        }
        switch subcommand {
        case "list", "ls":
            for preset in runtime.presets.presets() {
                print("\(preset.name)\t\(preset.id.uuidString)\t\(preset.entries.count) display(s)")
            }
        case "capture", "save":
            guard let name = args.dropFirst().first else { throw CLIError.message("Usage: nitsctl preset capture <name> [--icon symbol]") }
            guard let preset = await runtime.presets.capture(name: name, icon: options.icon ?? "display") else {
                throw CLIError.message("Could not capture a preset")
            }
            let saved = runtime.presets.save(preset)
            runtime.syncHotkeys()
            print("Saved preset '\(saved.name)' (\(saved.id.uuidString))")
        case "apply":
            guard let name = args.dropFirst().first else { throw CLIError.message("Usage: nitsctl preset apply <name>") }
            guard let preset = runtime.presets.preset(named: name) else {
                throw CLIError.message("No preset named '\(name)'")
            }
            let result = await runtime.presets.apply(preset)
            print(result.summary)
            if !result.errors.isEmpty { throw CLIError.message(result.errors.joined(separator: "; ")) }
        case "delete", "rm":
            guard let name = args.dropFirst().first, let preset = runtime.presets.preset(named: name) else {
                throw CLIError.message("No such preset")
            }
            runtime.presets.delete(id: preset.id)
            runtime.syncHotkeys()
            print("Deleted '\(preset.name)'")
        default:
            throw CLIError.message("Unknown preset command '\(subcommand)'")
        }
    }

    // MARK: - Connect / HiDPI

    private static func disconnect(options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let result = await runtime.disconnect(display)
        switch result {
        case .success:
            print("Disconnected \(display.name). Reconnect with: nitsctl reconnect \(display.uuid)")
        case .failure(let error):
            throw CLIError.message(error.description)
        }
    }

    private static func reconnect(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let records = runtime.disconnectedDisplays()
        guard !records.isEmpty else { throw CLIError.message("No disconnected displays") }
        let term = args.first ?? options.display
        let record: DisconnectedDisplay
        if let term {
            guard let match = records.first(where: {
                $0.uuid.lowercased().hasPrefix(term.lowercased()) ||
                $0.name.lowercased().contains(term.lowercased()) ||
                String($0.displayID) == term
            }) else {
                throw CLIError.message("No disconnected display matching '\(term)'")
            }
            record = match
        } else if records.count == 1 {
            record = records[0]
        } else {
            throw CLIError.message("Disconnected: \(records.map { "\($0.name) [\($0.uuid)]" }.joined(separator: ", "))")
        }
        let result = await runtime.reconnect(uuid: record.uuid)
        switch result {
        case .success: print("Reconnected \(record.name)")
        case .failure(let error): throw CLIError.message(error.description)
        }
    }

    private static func rename(args: [String], options: Options, runtime: NitsRuntime) throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let requested = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if requested.isEmpty || requested == "--clear" {
            runtime.setDisplayName(nil, for: display)
            print("\(display.name): using the monitor's own name")
        } else {
            runtime.setDisplayName(requested, for: display)
            print("\(display.name): renamed to \(requested)")
        }
        runtime.config.save()
    }

    private static func edid(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)

        if args.first == "override" {
            guard args.count >= 2 else {
                throw CLIError.message("Usage: nitsctl edid override <file.edid>")
            }
            let url = URL(fileURLWithPath: args[1])
            let data = try Data(contentsOf: url)
            if let problem = EDIDOverride.validate(data) {
                throw CLIError.message("Invalid EDID: \(problem)")
            }
            let result = await runtime.installEDIDOverride(data, for: display)
            if result.succeeded {
                print("Installed \(data.count)-byte EDID override for \(display.name)")
            } else {
                throw CLIError.message(result.message ?? "EDID override failed")
            }
            return
        }

        if args.first == "restore" {
            let result = await runtime.restoreEDIDOverride(for: display)
            if result.succeeded {
                print("Restored \(display.name)\(result.message.map { " (\($0))" } ?? "")")
            } else {
                throw CLIError.message(result.message ?? "EDID restore failed")
            }
            return
        }

        guard let info = EDIDService.read(display: display) else {
            throw CLIError.message("No EDID available for \(display.name)")
        }

        if let path = options.exportPath ?? args.first {
            let url = URL(fileURLWithPath: path)
            try info.raw.write(to: url)
            print("Wrote \(info.raw.count) EDID bytes to \(url.path)")
            return
        }

        if options.json {
            print(try encode(info))
            return
        }

        print("\(display.name)")
        print("  manufacturer: \(info.manufacturer ?? "unknown")")
        print("  product:      \(info.productName ?? "unknown")\(info.productCode.map { String(format: " (0x%04X)", $0) } ?? "")")
        print("  serial:       \(info.serialNumber.map(String.init) ?? "unknown")")
        if let year = info.yearOfManufacture {
            print("  manufactured: \(info.weekOfManufacture.map { "week \($0), " } ?? "")\(year)")
        }
        if let width = info.widthCM, let height = info.heightCM {
            print("  size:         \(width) × \(height) cm")
        }
        print("  bytes:        \(info.raw.count)")
    }

    private static func hidpi(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        switch args.first ?? "status" {
        case "status":
            let installed = HiDPIOverride.isInstalled(
                vendor: display.identity.vendor,
                product: display.identity.product
            )
            let modes = runtime.resolution.modes(for: display.id)
            let hidpiCount = modes.filter(\.isHiDPI).count
            print("\(display.name): override \(installed ? "installed" : "not installed"), \(hidpiCount) HiDPI mode(s)")
        case "enable", "on":
            let result = await runtime.enableHiDPI(display, dense: options.dense)
            if result.succeeded {
                print("HiDPI enabled for \(display.name)\(options.dense ? " (smooth ladder)" : "")")
            } else {
                throw CLIError.message(result.message ?? "HiDPI enable failed")
            }
        case "disable", "off":
            let result = await runtime.disableHiDPI(display)
            if result.succeeded {
                print("HiDPI override removed for \(display.name)")
            } else {
                throw CLIError.message(result.message ?? "HiDPI remove failed")
            }
        default:
            throw CLIError.message("Usage: nitsctl hidpi status|enable|disable [--dense] [--display]")
        }
    }

    // MARK: - Image

    private static func groups(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list", "ls":
            let groups = runtime.groups()
            guard !groups.isEmpty else {
                print("No groups configured.")
                return
            }
            let names = Dictionary(uniqueKeysWithValues: runtime.displays().map { ($0.uuid, $0.name) })
            for group in groups {
                let members = group.displayUUIDs.compactMap { names[$0] }.joined(separator: ", ")
                var flags: [String] = []
                if group.syncBrightness { flags.append("brightness") }
                if group.syncVolume { flags.append("volume") }
                if group.syncImage { flags.append("image") }
                if group.syncInput { flags.append("input") }
                if group.syncResolution { flags.append("resolution") }
                print("\(group.name)\t\(group.id.uuidString)\t\(members)\t[\(flags.joined(separator: ", "))]")
            }
        case "create":
            guard args.count >= 3 else {
                throw CLIError.message("Usage: nitsctl group create <name> <display> [<display>...] [--sync brightness,image,...]")
            }
            let name = args[1]
            var members: [DisplaySnapshot] = []
            for term in args.dropFirst(2) {
                guard let display = DisplaySelector.match(term, in: runtime.displays()) else {
                    throw CLIError.message("No display matching '\(term)'")
                }
                if !members.contains(where: { $0.uuid == display.uuid }) {
                    members.append(display)
                }
            }
            guard !members.isEmpty else { throw CLIError.message("A group needs at least one display") }
            let features = options.syncFeatures.isEmpty ? ["brightness"] : options.syncFeatures
            let group = DisplayGroup(
                name: name,
                displayUUIDs: members.map(\.uuid),
                syncBrightness: features.contains("brightness"),
                syncVolume: features.contains("volume"),
                syncImage: features.contains("image"),
                syncInput: features.contains("input"),
                syncResolution: features.contains("resolution")
            )
            runtime.saveGroup(group)
            runtime.config.save()
            print("Created group \(group.name) with \(members.count) display(s)")
        case "delete", "rm":
            guard let term = args.dropFirst().first else {
                throw CLIError.message("Usage: nitsctl group delete <name|uuid>")
            }
            guard let group = runtime.groups().first(where: {
                $0.id.uuidString.lowercased().hasPrefix(term.lowercased())
                    || $0.name.localizedCaseInsensitiveContains(term)
            }) else {
                throw CLIError.message("No group matching '\(term)'")
            }
            runtime.deleteGroup(id: group.id)
            runtime.config.save()
            print("Deleted group \(group.name)")
        default:
            throw CLIError.message("Usage: nitsctl group list|create|delete")
        }
    }

    private static func eventActions(args: [String], options: Options, runtime: NitsRuntime) throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list", "ls":
            var found = false
            for event in DisplayEventAction.Event.allCases {
                if let action = runtime.eventAction(for: display, event: event) {
                    found = true
                    print("\(event.rawValue)\t\(action.kind.rawValue)\t\(action.value)")
                }
            }
            if !found { print("No actions configured for \(display.name)") }
        case "set":
            guard args.count >= 4,
                  let event = DisplayEventAction.Event(rawValue: args[1].lowercased()),
                  let kind = DisplayEventAction.Kind(rawValue: args[2].lowercased())
            else {
                throw CLIError.message("Usage: nitsctl action set <connect|disconnect|sleep|wake> <preset|url|script> <value>")
            }
            let value = args.dropFirst(3).joined(separator: " ")
            guard !value.isEmpty else { throw CLIError.message("Action value required") }
            runtime.setEventAction(
                DisplayEventAction(event: event, kind: kind, value: value),
                for: display,
                event: event
            )
            runtime.config.save()
            print("\(display.name): \(event.rawValue) → \(kind.rawValue) \(value)")
        case "remove", "rm":
            guard args.count >= 2,
                  let event = DisplayEventAction.Event(rawValue: args[1].lowercased())
            else {
                throw CLIError.message("Usage: nitsctl action remove <connect|disconnect|sleep|wake>")
            }
            runtime.setEventAction(nil, for: display, event: event)
            runtime.config.save()
            print("\(display.name): removed \(event.rawValue) action")
        default:
            throw CLIError.message("Usage: nitsctl action list|set|remove")
        }
    }

    private static func virtual(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list", "ls":
            let configurations = runtime.virtualDisplays.configs
            if options.json {
                print(try encode(configurations))
                return
            }
            if configurations.isEmpty {
                print("No virtual displays configured.")
                return
            }
            for configuration in configurations {
                let auto = configuration.autoCreate ? "auto" : "manual"
                print("\(configuration.name)\t\(configuration.id.uuidString)\t\(configuration.label)\t\(auto)")
            }
        case "create":
            guard let size = args.dropFirst().first else {
                throw CLIError.message("Usage: nitsctl virtual create <WxH> [name] [--name name] [--refresh 60] [--nohidpi] [--noauto]")
            }
            let parts = size.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
                throw CLIError.message("Invalid size '\(size)'. Use WIDTHxHEIGHT.")
            }
            let fallbackName = args.dropFirst(2).joined(separator: " ")
            let name = options.name ?? (fallbackName.isEmpty ? "Virtual Display" : fallbackName)
            let configuration = VirtualDisplayConfig(
                name: name,
                width: width,
                height: height,
                refreshRate: options.refresh ?? 60,
                hiDPI: !options.noHiDPI,
                autoCreate: !options.noAuto
            )
            guard let data = try? JSONEncoder().encode(configuration) else {
                throw CLIError.message("Could not encode the configuration")
            }
            guard let response = ControlClient.send(
                "virtual-create \(data.base64EncodedString())",
                timeout: 5
            ) else {
                throw CLIError.message("Nits must be running to create a virtual display (open /Applications/Nits.app).")
            }
            print(response)
        case "remove", "rm":
            guard let term = args.dropFirst().first else {
                throw CLIError.message("Usage: nitsctl virtual remove <name|uuid>")
            }
            if let response = ControlClient.send("virtual-remove \(term)", timeout: 5) {
                print(response)
                return
            }
            guard let configuration = runtime.virtualDisplays.configs.first(where: {
                $0.id.uuidString.lowercased().hasPrefix(term.lowercased())
                    || $0.name.localizedCaseInsensitiveContains(term)
            }) else {
                throw CLIError.message("No virtual display matching '\(term)'")
            }
            runtime.virtualDisplays.remove(id: configuration.id)
            print("Removed \(configuration.name)")
        case "auto":
            guard args.count >= 3 else {
                throw CLIError.message("Usage: nitsctl virtual auto <name> on|off")
            }
            let term = args[1]
            let on = args[2].lowercased() != "off"
            guard let configuration = runtime.virtualDisplays.configs.first(where: {
                $0.id.uuidString.lowercased().hasPrefix(term.lowercased())
                    || $0.name.localizedCaseInsensitiveContains(term)
            }) else {
                throw CLIError.message("No virtual display matching '\(term)'")
            }
            runtime.virtualDisplays.setAutoCreate(on, id: configuration.id)
            print("\(configuration.name): auto-create \(on ? "on" : "off")")
        default:
            throw CLIError.message("Usage: nitsctl virtual list|create <WxH>|remove <name>|auto <name> on|off")
        }
    }

    private static func colorProfile(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let subcommand = args.first ?? "list"

        switch subcommand {
        case "list", "ls":
            let profiles = await runtime.profiles(for: display)
            let current = runtime.currentProfileName(for: display)
            if options.json {
                print(try encode(profiles))
                return
            }
            print("\(display.name) · current: \(current)")
            for profile in profiles {
                let marker = profile.name == current ? "*" : " "
                print("\(marker) \(profile.name)\t\(profile.path.path)")
            }
        case "current":
            print(runtime.currentProfileName(for: display))
        case "set":
            guard let term = args.dropFirst().first else {
                throw CLIError.message("Usage: nitsctl profile set <name|path> [--display]")
            }
            let profiles = await runtime.profiles(for: display)
            let profile: ICCProfile?
            if term.contains("/"), FileManager.default.fileExists(atPath: term) {
                profile = ColorProfileService.loadProfile(at: URL(fileURLWithPath: term))
            } else {
                profile = profiles.first {
                    $0.name.localizedCaseInsensitiveCompare(term) == .orderedSame
                        || $0.name.localizedCaseInsensitiveContains(term)
                }
            }
            guard let profile else {
                throw CLIError.message("No color profile matching '\(term)'")
            }
            guard runtime.setProfile(profile, for: display) else {
                throw CLIError.message("Could not assign \(profile.name)")
            }
            print("\(display.name): \(profile.name)")
        default:
            throw CLIError.message("Usage: nitsctl profile list|current|set <name|path>")
        }
    }

    private static func gamma(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        guard let subcommand = args.first else {
            let adjustment = (await runtime.state(for: display)).gamma
            if options.json { print(try encode(adjustment)) } else { print(describe(adjustment)) }
            return
        }
        if subcommand == "reset" || subcommand == "off" {
            runtime.setGamma(GammaAdjustment(), for: display)
            print("\(display.name): image adjustment reset")
            return
        }
        if subcommand == "show" {
            let adjustment = (await runtime.state(for: display)).gamma
            if options.json { print(try encode(adjustment)) } else { print(describe(adjustment)) }
            return
        }
        var adjustment = (await runtime.state(for: display)).gamma
        let pairs = subcommand == "set" ? Array(args.dropFirst()) : Array(args)
        guard !pairs.isEmpty else { throw CLIError.message("Usage: nitsctl gamma set contrast=10 gamma=5 temp=20 ...") }
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].lowercased()
            if key == "invert" {
                adjustment.isInverted = parts.count < 2 || parts[1] != "0"
                continue
            }
            guard parts.count == 2, let value = Double(parts[1]) else {
                throw CLIError.message("Invalid setting '\(pair)'")
            }
            switch key {
            case "contrast": adjustment.contrast = value
            case "gamma": adjustment.gamma = value
            case "gain": adjustment.gain = value
            case "temp", "temperature": adjustment.colorTemperature = value
            case "rgamma", "redgamma": adjustment.redGamma = value
            case "ggamma", "greengamma": adjustment.greenGamma = value
            case "bgamma", "bluegamma": adjustment.blueGamma = value
            case "rgain", "redgain": adjustment.redGain = value
            case "ggain", "greengain": adjustment.greenGain = value
            case "bgain", "bluegain": adjustment.blueGain = value
            case "quantize", "quantization": adjustment.quantizationLevels = Int(value)
            default: throw CLIError.message("Unknown image setting '\(key)'")
            }
        }
        runtime.setGamma(adjustment, for: display)
        print("\(display.name): \(describe(adjustment))")
    }

    private static func hdr(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let on = (args.first ?? "on") != "off"
        runtime.setHDRSoftwareDimming(on, for: display)
        print("\(display.name): HDR software dimming \(on ? "on" : "off")")
    }

    private static func extra(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let display = try resolveDisplay(options: options, runtime: runtime)
        let on = (args.first ?? "on") != "off"
        runtime.setExtraBrightness(on, for: display)
        print("\(display.name): extra brightness \(on ? "on" : "off")")
    }

    private static func sync(args: [String], options: Options, runtime: NitsRuntime) async throws {
        let on = (args.first ?? "on") != "off"
        runtime.updateGeneral { $0.syncBrightness = on }
        print("Brightness sync \(on ? "on" : "off")")
    }

    // MARK: - System

    private static func system(args: [String], options: Options, runtime: NitsRuntime) async throws {
        guard let feature = args.first else {
            throw CLIError.message("Usage: nitsctl system keepawake|darkmode|launchlogin <on|off|toggle|status>")
        }
        switch feature {
        case "keepawake":
            let action = args.dropFirst().first ?? "toggle"
            if action == "status" {
                if let response = ControlClient.send("keepawake status") {
                    print(response)
                } else {
                    let on = runtime.config.snapshot().general.keepAwake
                    print("keep awake: \(on ? "on" : "off") (Nits is not running)")
                }
                break
            }
            if let response = ControlClient.send("keepawake \(action)") {
                print(response)
            } else {
                let target = action == "toggle"
                    ? !runtime.config.snapshot().general.keepAwake
                    : action != "off"
                runtime.updateGeneral { $0.keepAwake = target }
                print("Keep awake \(target ? "on" : "off") saved for the next Nits launch (app is not running).")
            }
        case "nightshift", "night-shift":
            let action = args.dropFirst().first ?? "toggle"
            if action == "status" {
                let state = runtime.nightShiftEnabled() ? "on" : "off"
                print("Night Shift: \(state)")
                break
            }
            guard runtime.coreBrightness.nightShiftAvailable else {
                throw CLIError.message("Night Shift is not available on this Mac")
            }
            let target = action == "toggle" ? !runtime.nightShiftEnabled() : action != "off"
            _ = runtime.setNightShift(target)
            print("Night Shift: \(target ? "on" : "off")")
        case "truetone", "true-tone":
            let action = args.dropFirst().first ?? "toggle"
            if action == "status" {
                let state = runtime.trueToneEnabled() ? "on" : "off"
                print("True Tone: \(state)")
                break
            }
            guard runtime.coreBrightness.trueToneAvailable else {
                throw CLIError.message("True Tone is not available on this Mac")
            }
            let target = action == "toggle" ? !runtime.trueToneEnabled() : action != "off"
            _ = runtime.setTrueTone(target)
            print("True Tone: \(target ? "on" : "off")")
        case "darkmode":
            let action = args.dropFirst().first ?? "toggle"
            if let response = ControlClient.send("darkmode \(action)") {
                print(response)
                break
            }
            if action == "status" {
                print("Dark mode: \(SystemToggles.isDarkMode ? "on" : "off")")
            } else {
                let target = action == "toggle" ? !SystemToggles.isDarkMode : action == "on"
                if SystemToggles.setDarkMode(target) == true {
                    print("Dark mode: \(target ? "on" : "off")")
                } else {
                    throw CLIError.message("Dark mode toggle failed (Automation permission?)")
                }
            }
        case "launchlogin":
            let action = args.dropFirst().first ?? "status"
            if action == "status" {
                print("Launch at login: \(LaunchAtLogin.statusDescription)")
            } else {
                let ok = LaunchAtLogin.setEnabled(action != "off")
                print("Launch at login: \(ok ? LaunchAtLogin.statusDescription : "failed (app bundle required)")")
            }
        default:
            throw CLIError.message("Unknown system feature '\(feature)'")
        }
    }

    private static func configCommand(args: [String], runtime: NitsRuntime) {
        switch args.first ?? "path" {
        case "path":
            print(runtime.config.url.path)
        case "show":
            print(runtime.config.url.path)
            if let text = try? String(contentsOf: runtime.config.url, encoding: .utf8) {
                print(text)
            }
        default:
            print("Usage: nitsctl config path|show")
        }
    }

    private static func doctor(runtime: NitsRuntime, json: Bool) async throws {
        let report = await Doctor.run(runtime: runtime)
        print(json ? Doctor.renderJSON(report) : Doctor.renderText(report))
    }

    private static func watch(options: Options, runtime: NitsRuntime) async throws {
        let interval = max(0.25, options.interval ?? 1.0)
        while true {
            let states = await runtime.states(refresh: true)
            if options.json {
                print(try encode(states))
            } else {
                let line = states.map { state -> String in
                    let brightness = state.brightness.map { String(format: "%.0f", $0) } ?? "?"
                    return "\(state.display.name):\(brightness)%"
                }.joined(separator: "  ")
                print(line)
            }
            fflush(stdout)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // MARK: - Helpers

    private struct Options {
        var json = false
        var display: String?
        var configURL = NitsPaths.configFile
        var dense = false
        var interval: Double?
        var onto: String?
        var icon: String?
        var exportPath: String?
        var name: String?
        var refresh: Double?
        var noHiDPI = false
        var noAuto = false
        var syncFeatures: [String] = []

        mutating func parse(_ arguments: [String]) throws -> [String] {
            var positionals: [String] = []
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--json", "-j": json = true
                case "--dense": dense = true
                case "--display", "-d":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--display needs a value") }
                    display = arguments[index]
                case let value where value.hasPrefix("--display="):
                    display = String(value.dropFirst("--display=".count))
                case "--config":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--config needs a path") }
                    configURL = URL(fileURLWithPath: arguments[index])
                case "--interval":
                    index += 1
                    guard index < arguments.count, let seconds = Double(arguments[index]) else {
                        throw CLIError.message("--interval needs seconds")
                    }
                    interval = seconds
                case "--onto":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--onto needs a display") }
                    onto = arguments[index]
                case "--icon":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--icon needs a symbol name") }
                    icon = arguments[index]
                case "--export", "--output", "-o":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--export needs a path") }
                    exportPath = arguments[index]
                case "--name":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--name needs a value") }
                    name = arguments[index]
                case "--refresh":
                    index += 1
                    guard index < arguments.count, let value = Double(arguments[index]) else {
                        throw CLIError.message("--refresh needs a number")
                    }
                    refresh = value
                case "--nohidpi":
                    noHiDPI = true
                case "--noauto":
                    noAuto = true
                case "--sync":
                    index += 1
                    guard index < arguments.count else { throw CLIError.message("--sync needs a list") }
                    syncFeatures = arguments[index]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                case "--help", "-h":
                    printHelp()
                    exit(0)
                default:
                    positionals.append(argument)
                }
                index += 1
            }
            return positionals
        }
    }

    private static func resolveDisplay(options: Options, runtime: NitsRuntime) throws -> DisplaySnapshot {
        let displays = runtime.displays()
        guard !displays.isEmpty else { throw CLIError.message("No displays") }
        guard let match = DisplaySelector.match(options.display, in: displays) else {
            throw CLIError.message("No display matching '\(options.display ?? "")'")
        }
        return match
    }

    private static func resolveDisplays(options: Options, runtime: NitsRuntime) throws -> [DisplaySnapshot] {
        let displays = runtime.displays()
        guard !displays.isEmpty else { throw CLIError.message("No displays") }
        if options.display?.lowercased() == "all" { return displays }
        return [try resolveDisplay(options: options, runtime: runtime)]
    }

    private static func parseVCPCode(_ text: String) -> UInt8? {
        if text.lowercased().hasPrefix("0x") {
            return UInt8(text.dropFirst(2), radix: 16)
        }
        return UInt8(text, radix: 16) ?? UInt8(text)
    }

    private static func parseUInt16(_ text: String) throws -> UInt16 {
        if text.lowercased().hasPrefix("0x"), let value = UInt16(text.dropFirst(2), radix: 16) {
            return value
        }
        guard let value = UInt16(text) else { throw CLIError.message("Invalid value '\(text)'") }
        return value
    }

    private static func parseDouble(_ text: String, name: String) throws -> Double {
        guard let value = Double(text) else { throw CLIError.message("Invalid \(name) '\(text)'") }
        return value
    }

    private static func parseDelta(_ text: String) -> Double? {
        guard text.hasPrefix("+") || text.hasPrefix("-"), let value = Double(text) else { return nil }
        return value
    }

    private static func parseModeSpec(_ text: String, hiDPIFlag: Bool) throws -> ModeSpec {
        var body = text
        var refresh: Double?
        var hiDPI = hiDPIFlag

        if let at = body.firstIndex(of: "@") {
            let refreshText = String(body[body.index(after: at)...]).lowercased()
                .replacingOccurrences(of: "hz", with: "")
            guard let parsed = Double(refreshText) else {
                throw CLIError.message("Invalid refresh rate in '\(text)'")
            }
            refresh = parsed
            body = String(body[..<at])
        }
        if body.lowercased().hasSuffix("hidpi") {
            hiDPI = true
            body = String(body.dropLast("hidpi".count)).trimmingCharacters(in: .whitespaces)
        }
        let parts = body.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            throw CLIError.message("Invalid resolution '\(text)'. Use WIDTHxHEIGHT[@HZ] [hidpi].")
        }
        return ModeSpec(width: width, height: height, refreshRate: refresh, hiDPI: hiDPI)
    }

    private static func formatInput(_ value: UInt16) -> String {
        let name = InputSource.name(for: value) ?? "Input"
        return "\(name) (0x\(String(format: "%02X", value)))"
    }

    private static func describe(_ adjustment: GammaAdjustment) -> String {
        if adjustment.isNeutral { return "image adjustment neutral" }
        return """
        contrast=\(adjustment.contrast) gamma=\(adjustment.gamma) gain=\(adjustment.gain) \
        temp=\(adjustment.colorTemperature) invert=\(adjustment.isInverted) \
        quantize=\(adjustment.quantizationLevels)
        """
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func encode(_ dictionary: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(dictionary) else { return "{}" }
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("nitsctl: " + message + "\n").utf8))
    }

    private static func printHelp() {
        print("""
        Nits \(NitsVersion.current) — display control for macOS

        USAGE
          nitsctl [--display <selector>] [--json] <command> [arguments]
          nitsctl <command> help

        GLOBAL
          --display, -d   main | builtin | external | all | <id> | <uuid prefix> | <name>
          --json, -j      machine-readable output
          --config PATH   use an alternate config file

        DISPLAYS
          list                              every display with brightness, volume and mode
          brightness [%|+N|-N]              read or set brightness
          volume [%|+N|-N]                  read or set DDC speaker volume
          contrast [%]                      read or set hardware contrast
          mute                              toggle monitor mute (zero-volume fallback)
          input [value|list]                show or change the monitor input
          get <vcp> / set <vcp> <value>     raw DDC/CI VCP access

        RESOLUTION
          mode [list]                       list modes
          mode set <WxH>[@Hz] [hidpi]       apply a mode
          mode hidpi                        toggle the HiDPI twin of the current size
          mode scale [list|up|down|<n>]     step the "looks like" size (larger text ↔ more space)
          rotate <0|90|180|270>             rotate a display
          main                              make the selected display main
          rename <name>                     override the display name (--clear to reset)
          edid [--export <path>]            read or export the raw EDID block
          edid override <file>              install an EDID override (admin)
          edid restore                      remove the EDID override (admin)
          profile list|current|set <name>   ICC color profiles
          mirror [--onto <display>]         mirror onto another display
          unmirror                          stop mirroring
          hidpi status|enable|disable [--dense]
                                            install/remove the HiDPI override (admin)

        ACTIONS
          action list                       per-display connect/disconnect/sleep/wake actions
          action set <event> <kind> <value> preset | url | script
          action remove <event>

        GROUPS
          group list
          group create <name> <display> [<display>...] [--sync brightness,image,...]
          group delete <name|uuid>

        VIRTUAL DISPLAYS
          virtual list
          virtual create <WxH> [name] [--refresh 60] [--nohidpi] [--noauto]
          virtual remove <name|uuid>
          virtual auto <name> on|off
                                            requires the Nits app to be running

        PRESETS
          preset list
          preset capture <name> [--icon <sf-symbol>]
          preset apply <name>
          preset delete <name>

        DISPLAY CONTROL
          disconnect                        turn the selected display off
          reconnect [id|uuid|name]          turn a disconnected display back on
          gamma [show]                      show software image adjustment
          gamma set contrast=10 gamma=5 temp=20 invert=1
          gamma reset
          hdr on|off                        route brightness through gamma (HDR monitors)
          extra on|off                      lift output above 100% on external panels
          sync on|off                       synchronize brightness across displays

        SYSTEM
          system keepawake on|off|toggle|status
          system darkmode on|off|toggle|status
          system nightshift on|off|toggle|status
          system truetone on|off|toggle|status
          system launchlogin on|off|status
          config path|show
          doctor [--json]                   full diagnostic report
          watch [--interval 1]              stream state as JSON (or one line per tick)
          version
        """)
    }
}

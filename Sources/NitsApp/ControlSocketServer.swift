import AppKit
import Foundation
import NitsCore

/// Accepts one-line commands from `nitsctl` over a Unix socket in Application Support.
/// It exists for actions that belong to the live app: keep-awake assertions, preset
/// application and UI refresh. Hardware commands never need it.
final class ControlSocketServer: @unchecked Sendable {
    private let model: AppModel
    private let path: String
    private var descriptor: Int32 = -1
    private let queue = DispatchQueue(label: "app.nits.control", qos: .userInitiated)

    init(model: AppModel) {
        self.model = model
        self.path = NitsPaths.controlSocket.path
    }

    func start() {
        NitsPaths.ensureApplicationSupport()
        unlink(path)

        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            NitsLog.app.error("control socket could not be created")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = strncpy(destination, path, 103)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, size)
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            NitsLog.app.error("control socket could not bind at \(self.path, privacy: .public)")
            close(descriptor)
            descriptor = -1
            return
        }
        // Only the logged-in user should be able to drive displays through this socket.
        _ = chmod(path, 0o600)

        queue.async { [weak self] in
            self?.acceptLoop()
        }
        NitsLog.app.notice("control socket listening")
    }

    func stop() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while descriptor >= 0 {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if descriptor < 0 { return }
                continue
            }
            // Never dispatch a handler back onto `queue`: that serial queue is parked
            // inside accept() for the lifetime of the server.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !data.contains(0x0A) {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        guard let command = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty
        else { return }

        let response = DispatchQueue.main.sync { () -> String in
            MainActor.assumeIsolated {
                self.route(command)
            }
        }
        let payload = Array((response + "\n").utf8)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    @MainActor
    private func route(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? String(parts[1]) : ""

        switch verb {
        case "ping":
            return "ok"
        case "keepawake":
            let action = argument.lowercased()
            if action == "status" {
                return "keep awake: \(model.keepAwake ? "on" : "off")"
            }
            let target = action == "toggle" ? !model.keepAwake : action != "off"
            model.setKeepAwake(target)
            return "keep awake: \(model.keepAwake ? "on" : "off")"
        case "reload":
            model.reloadFromDisk()
            return "reloaded"
        case "preset":
            let term = argument.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return "preset name required" }
            guard let preset = model.presets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(term) == .orderedSame
                    || $0.id.uuidString.lowercased().hasPrefix(term.lowercased())
            }) else {
                return "no preset named \(term)"
            }
            model.applyPreset(id: preset.id)
            return "applying \(preset.name)"
        case "virtual-create":
            guard let data = Data(base64Encoded: argument),
                  let configuration = try? JSONDecoder().decode(VirtualDisplayConfig.self, from: data)
            else { return "invalid virtual display config" }
            model.createVirtualDisplay(configuration)
            return "creating \(configuration.name)"
        case "virtual-remove":
            let term = argument.lowercased()
            guard let configuration = model.virtualConfigs.first(where: {
                $0.id.uuidString.lowercased().hasPrefix(term)
                    || $0.name.lowercased().contains(term)
            }) else { return "no virtual display matching \(argument)" }
            model.removeVirtualDisplay(id: configuration.id)
            return "removed \(configuration.name)"
        case "virtual-list":
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(model.virtualConfigs),
                  let text = String(data: data, encoding: .utf8)
            else { return "[]" }
            return text
        case "darkmode":
            let action = argument.lowercased()
            if action == "status" {
                return "dark mode: \(model.isDarkMode ? "on" : "off")"
            }
            if action == "toggle" || action.isEmpty {
                model.toggleDarkMode()
            } else if let target = SystemToggles.setDarkMode(action != "off") {
                model.isDarkMode = target
            }
            return "dark mode: \(model.isDarkMode ? "on" : "off")"
        case "quit":
            NSApp.terminate(nil)
            return "quitting"
        default:
            return "unknown command \(verb)"
        }
    }
}

import AppKit
import NitsCore

/// `nits://` URLs: a tiny, scriptable surface that mirrors the CLI.
///
///   nits://brightness?value=40&display=main
///   nits://volume/value/40
///   nits://input?value=hdmi1&display=studio
///   nits://mode?width=2560&height=1440&refresh=120&hidpi=1
///   nits://preset/Work
///   nits://toggle-hidpi
///   nits://keepawake?on=1
///   nits://darkmode?on=1
@MainActor
enum URLHandler {
    static func handle(_ url: URL, model: AppModel) {
        guard url.scheme?.lowercased() == "nits",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            }
        )
        var path = components.path.split(separator: "/").map(String.init)
        let command = (url.host ?? path.first ?? "").lowercased()
        if url.host != nil { path = Array(path.dropFirst(0)) } else if !path.isEmpty {
            path.removeFirst()
        }
        // Use the runtime, not the UI rows: a cold-launch URL arrives before the panel
        // has loaded its first display list.
        let display = model.runtime.display(matching: params["display"])

        func double(_ key: String) -> Double? {
            params[key].flatMap(Double.init) ?? path.first.flatMap(Double.init)
        }

        switch command {
        case "brightness", "b":
            guard let value = double("value"), let display else { return }
            Task { _ = await model.runtime.setBrightness(value, for: display, wait: true) }
        case "volume", "v":
            guard let value = double("value"), let display else { return }
            Task { _ = await model.runtime.setVolume(value, for: display, wait: true) }
        case "contrast":
            guard let value = double("value"), let display else { return }
            Task { _ = await model.runtime.setContrast(value, for: display, wait: true) }
        case "mute":
            guard let display else { return }
            Task { _ = await model.runtime.toggleMute(for: display) }
        case "input":
            guard let display else { return }
            let text = params["value"] ?? path.first ?? ""
            guard let value = InputSource.value(from: text) else { return }
            Task { _ = await model.runtime.setInput(value, for: display) }
        case "mode", "resolution":
            guard let display,
                  let width = params["width"].flatMap(Int.init),
                  let height = params["height"].flatMap(Int.init)
            else { return }
            let refresh = params["refresh"].flatMap(Double.init)
            let hidpi = params["hidpi"].map { $0 == "1" || $0.lowercased() == "true" }
            Task {
                _ = await model.runtime.setMode(
                    width: width,
                    height: height,
                    refresh: refresh,
                    hiDPI: hidpi,
                    for: display
                )
            }
        case "preset":
            let term = params["name"] ?? path.first ?? ""
            guard let preset = model.presets.first(where: {
                $0.name.localizedCaseInsensitiveCompare(term) == .orderedSame
                    || $0.id.uuidString.lowercased().hasPrefix(term.lowercased())
            }) else { return }
            model.applyPreset(id: preset.id)
        case "toggle-hidpi", "hidpi":
            guard let display else { return }
            Task { _ = await model.runtime.toggleHiDPI(for: display) }
        case "keepawake":
            model.setKeepAwake(params["on"].map { $0 == "1" || $0.lowercased() == "true" } ?? true)
        case "darkmode":
            let target = params["on"].map { $0 == "1" || $0.lowercased() == "true" }
            if let target {
                _ = SystemToggles.setDarkMode(target)
                model.isDarkMode = target
            } else {
                model.toggleDarkMode()
            }
        default:
            NitsLog.app.notice("unhandled URL \(url.absoluteString, privacy: .public)")
        }
    }
}

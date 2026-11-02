import Foundation
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

public enum NitsVersion {
    public static let current = "0.3.0"
}

public struct DoctorReport: Codable, Sendable {
    public struct SystemInfo: Codable, Sendable {
        public var appVersion: String
        public var macOS: String
        public var architecture: String
        public var hostName: String
        public var accessibilityTrusted: Bool
        public var configPath: String
    }

    public struct PrivateAPIStatus: Codable, Sendable {
        public var displayServicesBrightness: Bool
        public var displayDisconnect: Bool
        public var hiddenModeFallback: Bool
        public var rotation: Bool
    }

    public struct Probe: Codable, Sendable {
        public var code: String
        public var name: String
        public var current: UInt16?
        public var maximum: UInt16?
        public var milliseconds: Double
        public var failure: String?
        public var reply: String
    }

    public struct DisplayReport: Codable, Sendable {
        public var display: DisplaySnapshot
        public var backend: String
        public var brightness: Double?
        public var volume: Double?
        public var volumeSupported: Bool?
        public var gamma: GammaAdjustment
        public var hdrSoftware: Bool
        public var extraBrightness: Bool
        public var hiDPIOverrideInstalled: Bool
        public var mirrorSource: UInt32?
        public var modeCount: Int
        public var currentMode: DisplayModeInfo?
        public var capabilities: DDCCapabilities?
        public var probes: [Probe]
        public var ddcReadsQuarantined: Bool
        public var notes: [String]
    }

    public var system: SystemInfo
    public var privateAPIs: PrivateAPIStatus
    public var displays: [DisplayReport]
    public var disconnected: [DisconnectedDisplay]
    public var presets: Int
    public var recentLog: [String]
    public var generatedAt: String
}

public enum Doctor {
    private static let probeNames: [(UInt8, String)] = [
        (DDCEngine.brightnessVCP, "brightness"),
        (DDCEngine.contrastVCP, "contrast"),
        (DDCEngine.volumeVCP, "volume"),
        (DDCEngine.inputVCP, "input"),
        (DDCEngine.powerVCP, "power"),
    ]

    public static func run(runtime: NitsRuntime) async -> DoctorReport {
        var displayReports: [DoctorReport.DisplayReport] = []
        let states = await runtime.states(refresh: true)

        for state in states {
            let display = state.display
            var probes: [DoctorReport.Probe] = []
            if !display.isBuiltin {
                for (code, name) in probeNames {
                    let probe = await runtime.ddc.probe(display: display, code: code)
                    probes.append(DoctorReport.Probe(
                        code: String(format: "0x%02X", code),
                        name: name,
                        current: probe.value?.current,
                        maximum: probe.value?.max,
                        milliseconds: (probe.milliseconds * 10).rounded() / 10,
                        failure: probe.failure,
                        reply: probe.reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    ))
                }
            }

            var notes: [String] = []
            if !display.isBuiltin, probes.allSatisfy({ $0.failure == "no DDC channel" }) {
                notes.append("No DDC channel found; brightness/volume fall back to software.")
            }
            if probes.contains(where: { $0.failure == "reply rejected (header/checksum/max)" }) {
                notes.append("Monitor returned replies that fail checksum/header validation; reads are untrusted.")
            }
            if runtime.ddc.readsQuarantined(displayID: display.id) {
                notes.append("DDC reads are quarantined for this display after repeated failures.")
            }
            if state.brightness == nil, !display.hasNativeBrightness {
                notes.append("Brightness could not be read; the slider will settle on the first successful write.")
            }
            if display.maximumEDR > 1.0 {
                notes.append("Display reports EDR headroom; HDR brightness may need software dimming.")
            }

            let capabilities = display.isBuiltin ? nil : await runtime.ddc.capabilities(display: display)

            displayReports.append(DoctorReport.DisplayReport(
                display: display,
                backend: state.backend.rawValue,
                brightness: state.brightness,
                volume: state.volume,
                volumeSupported: state.volumeSupported,
                gamma: state.gamma,
                hdrSoftware: state.hdrSoftware,
                extraBrightness: state.extraBrightness,
                hiDPIOverrideInstalled: HiDPIOverride.isInstalled(
                    vendor: display.identity.vendor,
                    product: display.identity.product
                ),
                mirrorSource: runtime.arrangement.mirrorSource(of: display.id),
                modeCount: state.modes.count,
                currentMode: state.currentMode,
                capabilities: capabilities,
                probes: probes,
                ddcReadsQuarantined: runtime.ddc.readsQuarantined(displayID: display.id),
                notes: notes
            ))
        }

        return DoctorReport(
            system: DoctorReport.SystemInfo(
                appVersion: NitsVersion.current,
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture(),
                hostName: ProcessInfo.processInfo.hostName,
                accessibilityTrusted: accessibilityTrusted(),
                configPath: runtime.config.url.path
            ),
            privateAPIs: DoctorReport.PrivateAPIStatus(
                displayServicesBrightness: NativeBrightness.shared.isAvailable,
                displayDisconnect: SkyLightSupport.shared.canDisconnect,
                hiddenModeFallback: SkyLightSupport.shared.canConfigureHiddenModes,
                rotation: SkyLightSupport.shared.canSetRotation
            ),
            displays: displayReports,
            disconnected: runtime.disconnectedDisplays(),
            presets: runtime.presets.presets().count,
            recentLog: NitsLog.recentLines(limit: 120),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func renderText(_ report: DoctorReport) -> String {
        var lines: [String] = []
        lines.append("Nits \(report.system.appVersion) diagnostics")
        lines.append("macOS \(report.system.macOS) · \(report.system.architecture) · \(report.system.hostName)")
        lines.append("Config: \(report.system.configPath)")
        lines.append("Accessibility: \(report.system.accessibilityTrusted ? "granted" : "not granted (media keys unavailable)")")
        lines.append("Private APIs: DisplayServices=\(report.privateAPIs.displayServicesBrightness) disconnect=\(report.privateAPIs.displayDisconnect) hiddenModes=\(report.privateAPIs.hiddenModeFallback) rotation=\(report.privateAPIs.rotation)")
        lines.append("Presets: \(report.presets)")

        for (index, item) in report.displays.enumerated() {
            let display = item.display
            lines.append("")
            lines.append("[\(index + 1)] \(display.name)  id=\(display.id)  uuid=\(display.uuid)")
            lines.append("    \(display.identity.vendorProduct) serial=\(display.identity.serial) \(display.connection)\(display.isBuiltin ? " built-in" : "")\(display.isMain ? " main" : "")")
            lines.append("    \(display.pixelWidth)×\(display.pixelHeight) px · native \(display.nativeWidth)×\(display.nativeHeight) · rotation \(Int(display.rotation))°")
            lines.append("    modes=\(item.modeCount) current=\(item.currentMode?.label ?? "unknown")")
            lines.append("    brightness=\(item.brightness.map { String(format: "%.1f%%", $0) } ?? "?") backend=\(item.backend) gamma=\(item.gamma.isNeutral ? "neutral" : "adjusted")")
            let volumeSupport = item.volumeSupported.map { $0 ? "yes" : "no" } ?? "unknown"
            lines.append("    volume=\(item.volume.map { String(format: "%.1f%%", $0) } ?? "?") supported=\(volumeSupport) HiDPI override=\(item.hiDPIOverrideInstalled)")
            if let source = item.mirrorSource {
                lines.append("    mirrors display \(source)")
            }
            if let capabilities = item.capabilities {
                lines.append("    MCCS \(capabilities.mccsVersion ?? "?") · VCP \(capabilities.vcpCodes.map { String(format: "%02X", $0) }.joined(separator: " "))")
                if let inputs = capabilities.inputs {
                    lines.append("    inputs \(inputs.map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
            }
            for probe in item.probes {
                let value = probe.current.map { "\($0)/\(probe.maximum ?? 0)" } ?? "—"
                let verdict = probe.failure.map { "FAIL \($0)" } ?? "ok"
                lines.append("    \(probe.code) \(probe.name): \(value) in \(probe.milliseconds) ms · \(verdict)")
                if probe.failure != nil, !probe.reply.isEmpty {
                    lines.append("        reply \(probe.reply)")
                }
            }
            for note in item.notes {
                lines.append("    note: \(note)")
            }
        }

        if !report.disconnected.isEmpty {
            lines.append("")
            lines.append("Disconnected: \(report.disconnected.map(\.name).joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Recent log:")
        for line in report.recentLog.suffix(40) {
            lines.append("  \(line)")
        }
        return lines.joined(separator: "\n")
    }

    public static func renderJSON(_ report: DoctorReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func architecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static func accessibilityTrusted() -> Bool {
#if canImport(ApplicationServices)
        return AXIsProcessTrusted()
#else
        return false
#endif
    }
}

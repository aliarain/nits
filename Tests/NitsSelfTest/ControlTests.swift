import Foundation
import NitsCore

func runControlTests() {
    harness.suite("Brightness mapping") {
        harness.equal(BrightnessController.hardwarePercent(for: 10), 15, "below 15% holds hardware at 15")
        harness.equal(BrightnessController.hardwarePercent(for: 128), 100, "values above 100 clamp hardware")
        harness.equal(BrightnessController.hardwarePercent(for: 50), 50, "mid range passes through")
        harness.approx(BrightnessController.gammaFactor(for: 7.5), 0.5, 0.001, "half of the blend range")
        harness.equal(BrightnessController.gammaFactor(for: 66), 1, "above the blend range gamma is neutral")
        harness.approx(BrightnessController.gammaFactor(for: 120), 1.2, 0.001, "extra brightness lifts gamma")
        harness.approx(BrightnessController.gammaFactor(for: 0), 0, 0.001, "zero requests full dimming")
        harness.approx(GammaEngine.minimumFactor(overlay: false), 0.01, 0.001, "table dimming never reaches black")
        harness.approx(GammaEngine.minimumFactor(overlay: true), 0, 0.001, "overlay dimming reaches true black")
        harness.approx(GammaEngine.overlayOpacity(forFactor: 0), 1, 0.001, "factor 0 is a fully black overlay")
        harness.approx(GammaEngine.overlayOpacity(forFactor: 0.4), 0.6, 0.001, "overlay opacity is the dim amount")
        harness.approx(GammaEngine.overlayOpacity(forFactor: 1.3), 0, 0.001, "lifted output has no overlay")
        harness.approx(GammaEngine.tableFactor(forFactor: 0.3, overlay: true), 1, 0.001, "overlay leaves the table neutral")
        harness.approx(GammaEngine.tableFactor(forFactor: 1.3, overlay: true), 1.3, 0.001, "overlay keeps extra brightness lift")
    }

    harness.suite("Volume and input") {
        harness.equal(DDCVolumeMax.from(0xFF64), 100, "Dell low-byte volume max")
        harness.equal(DDCVolumeMax.from(0x0064), 100, "ordinary volume max")
        harness.equal(DDCVolumeMax.from(0xFFC8), 200, "255-range monitors keep the low byte")
        harness.equal(DDCVolumeMax.from(0), 100, "zero max falls back to 100")
        harness.equal(InputSource.value(from: "hdmi1"), 0x11, "named HDMI input")
        harness.equal(InputSource.value(from: "dp2"), 0x10, "named DisplayPort input")
        harness.equal(InputSource.value(from: "usb-c"), 0x1B, "named USB-C input")
        harness.equal(InputSource.value(from: "0x11"), 0x11, "hex input")
        harness.equal(InputSource.value(from: "17"), 17, "decimal input")
        harness.equal(InputSource.current(fromReply: 0xFF11), 0x11, "input masks the high byte")
        harness.equal(InputSource.options(from: nil).count, 5, "standard input fallback")
    }

    harness.suite("Gamma math") {
        let neutral = GammaMath.tables(adjustment: GammaAdjustment(), softwareFactor: 1)
        harness.approx(neutral.red[0], 0, 0.001, "neutral table starts at zero")
        harness.approx(neutral.red[255], 1, 0.001, "neutral table ends at one")
        harness.approx(neutral.red[128], 128.0 / 255.0, 0.002, "neutral table is linear")

        let dimmed = GammaMath.tables(adjustment: GammaAdjustment(), softwareFactor: 0.5)
        harness.approx(dimmed.red[255], 0.5, 0.001, "software factor halves output")

        let warm = GammaMath.colorTemperatureFactors(0)
        harness.approx(warm.r, 1, 0.001, "6500 K is neutral red")
        harness.approx(warm.g, 1, 0.001, "6500 K is neutral green")
        harness.approx(warm.b, 1, 0.001, "6500 K is neutral blue")
        let cool = GammaMath.colorTemperatureFactors(-100)
        harness.check(cool.b > cool.r, "cooler setting raises blue over red")

        var invertedAdjustment = GammaAdjustment()
        invertedAdjustment.isInverted = true
        let inverted = GammaMath.tables(adjustment: invertedAdjustment, softwareFactor: 1)
        harness.approx(inverted.red[0], 1, 0.001, "inversion flips the low end")
        harness.approx(inverted.red[255], 0, 0.001, "inversion flips the high end")
    }

    harness.suite("HiDPI override planner") {
        let coarse = HiDPIOverride.coarseLogicalSizes(nativeWidth: 2560, nativeHeight: 1440)
        harness.equal(coarse.count, 4, "coarse ladder has native plus three stops")
        harness.equal(coarse.first?.width, 2560, "coarse ladder starts at native")
        harness.equal(coarse.last?.width, 1280, "coarse ladder ends at half width")

        let smooth = HiDPIOverride.smoothLogicalSizes(nativeWidth: 2560, nativeHeight: 1440)
        harness.check(smooth.count > 60, "smooth ladder is dense")
        harness.equal(smooth.first?.width, 2560, "smooth ladder starts at native")
        harness.equal(smooth.last?.height, 720, "smooth ladder holds the 16:9 aspect")
        harness.check(smooth.allSatisfy { $0.width >= 800 && $0.height >= 600 }, "smooth ladder respects minimums")

        let data = HiDPIOverride.scaleResolutionData(width: 1280, height: 720)
        harness.equal(Array(data), [0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x05, 0xA0], "scale-resolutions is 2x big-endian")
        let xml = HiDPIOverride.plistXML(scaleResolutions: [data])
        harness.check(xml.contains("scale-resolutions"), "plist has scale-resolutions")
        harness.check(xml.contains(data.base64EncodedString()), "plist embeds base64 data")
    }

    harness.suite("Config store") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nits-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ConfigStore(url: url)
        let preset = DisplayPreset(
            name: "Work",
            icon: "briefcase.fill",
            entries: [
                DisplayPresetEntry(
                    displayUUID: "AAA",
                    mode: ModeSpec(width: 2560, height: 1440, refreshRate: 120, hiDPI: true),
                    brightness: 42,
                    position: ArrangementPosition(x: 0, y: 0),
                    connected: true
                )
            ]
        )
        store.update { config in
            config.presets = [preset]
            config.general.brightnessStep = 12
            config.displaySettings["AAA"] = DisplaySettings()
            config.displaySettings["AAA"]?.gamma = GammaAdjustment()
            config.virtualDisplays = [
                VirtualDisplayConfig(name: "Virtual", width: 1280, height: 720)
            ]
            config.groups = [
                DisplayGroup(
                    name: "Desk",
                    displayUUIDs: ["AAA"],
                    syncBrightness: true,
                    syncImage: true
                )
            ]
            config.displaySettings["AAA"]?.defaultMode = ModeSpec(
                width: 2560, height: 1440, refreshRate: 120, hiDPI: true
            )
            config.displaySettings["AAA"]?.eventActions = [
                "connect": DisplayEventAction(
                    event: .connect,
                    kind: .url,
                    value: "nits://brightness?value=40"
                )
            ]
        }

        let reloaded = ConfigStore(url: url)
        harness.equal(reloaded.snapshot().presets.first?.name, "Work", "preset round-trips")
        harness.equal(reloaded.snapshot().presets.first?.entries.first?.mode?.hiDPI, true, "mode round-trips")
        harness.equal(reloaded.snapshot().general.brightnessStep, 12, "general setting round-trips")
        harness.equal(reloaded.snapshot().displaySettings["AAA"]?.gamma?.isNeutral, true, "gamma round-trips")
        harness.equal(reloaded.snapshot().virtualDisplays?.first?.name, "Virtual", "virtual display round-trips")
        harness.equal(reloaded.snapshot().virtualDisplays?.count, 1, "virtual display count")
        harness.equal(reloaded.snapshot().groups?.first?.name, "Desk", "display group round-trips")
        harness.equal(reloaded.snapshot().groups?.first?.syncImage, true, "group sync flags round-trip")
        harness.equal(
            reloaded.snapshot().displaySettings["AAA"]?.defaultMode?.width,
            2560,
            "default resolution round-trips"
        )
        harness.equal(
            reloaded.snapshot().displaySettings["AAA"]?.eventActions?["connect"]?.kind,
            .url,
            "event action round-trips"
        )

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nits-selftest-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        try? "{ not json".write(to: corruptURL, atomically: true, encoding: .utf8)
        let recovered = ConfigStore(url: corruptURL)
        harness.equal(recovered.snapshot().presets.count, 0, "corrupt config starts from defaults")
        let backups = try? FileManager.default.contentsOfDirectory(
            at: corruptURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("config.corrupt-") }
        harness.check((backups?.isEmpty == false), "corrupt config is preserved")
        if let backups {
            for backup in backups { try? FileManager.default.removeItem(at: backup) }
        }
    }

    harness.suite("Virtual displays and EDID overrides") {
        let configuration = VirtualDisplayConfig(
            name: "Studio",
            width: 2560,
            height: 1440,
            refreshRate: 60,
            hiDPI: true,
            autoCreate: true
        )
        let encoded = try! JSONEncoder().encode(configuration)
        let decoded = try! JSONDecoder().decode(VirtualDisplayConfig.self, from: encoded)
        harness.equal(decoded.name, "Studio", "virtual display config round-trips")
        harness.equal(decoded.hiDPI, true, "virtual display HiDPI round-trips")
        harness.check(decoded.label.contains("2560×1440"), "virtual display label")

        var invalidEDID = Data(repeating: 0, count: 128)
        harness.check(EDIDOverride.validate(invalidEDID) != nil, "zero EDID rejected")
        invalidEDID[0] = 0x00
        invalidEDID[1] = 0xFF
        invalidEDID[2] = 0xFF
        invalidEDID[3] = 0xFF
        invalidEDID[4] = 0xFF
        invalidEDID[5] = 0xFF
        invalidEDID[6] = 0xFF
        invalidEDID[7] = 0x00
        harness.nilValue(EDIDOverride.validate(invalidEDID), "valid 128-byte EDID accepted")
        harness.check(EDIDOverride.validate(Data(repeating: 0, count: 64)) != nil, "short EDID rejected")
        var wrongLength = invalidEDID
        wrongLength.append(0)
        harness.check(EDIDOverride.validate(wrongLength) != nil, "non-128-multiple EDID rejected")
    }

    harness.suite("Color profiles") {
        let monitor = ICCProfile(
            name: "Display P3",
            path: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc"),
            colorSpaceType: "RGB",
            deviceClass: "mntr"
        )
        harness.check(monitor.isDisplayProfile, "RGB monitor profile is assignable")
        let cmyk = ICCProfile(
            name: "Printer",
            path: URL(fileURLWithPath: "/tmp/printer.icc"),
            colorSpaceType: "CMYK",
            deviceClass: "prtr"
        )
        harness.check(!cmyk.isDisplayProfile, "CMYK printer profile is rejected")
        let working = ICCProfile(
            name: "sRGB",
            path: URL(fileURLWithPath: "/tmp/srgb.icc"),
            colorSpaceType: "RGB",
            deviceClass: "spac"
        )
        harness.check(working.isDisplayProfile, "RGB working-space profile is assignable")
    }

    harness.suite("Preset mode spec") {
        let mode = DisplayModeInfo(
            id: 7, width: 2560, height: 1440,
            pixelWidth: 5120, pixelHeight: 2880,
            refreshRate: 119.88, isHiDPI: true, isUsable: true
        )
        let spec = ModeSpec(mode: mode)
        harness.equal(spec.width, 2560, "preset keeps logical width")
        harness.equal(spec.hiDPI, true, "preset keeps HiDPI")
        harness.check(spec.label.contains("HiDPI"), "label describes scaling")

        let rotated = [
            DisplayModeInfo(
                id: 9, width: 1440, height: 2560,
                pixelWidth: 2880, pixelHeight: 5120,
                refreshRate: 60, isHiDPI: true, isUsable: true
            )
        ]
        let match = DisplayModeInfo.bestMatch(
            width: 2560, height: 1440, refresh: nil, hiDPI: true, in: rotated
        )
        harness.equal(match?.id, 9, "mode match tolerates a rotated panel")
    }
}

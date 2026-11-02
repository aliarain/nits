# Nits

**Free, open-source display control for macOS — a stable, BetterDisplay-class alternative.**

Nits is a menu bar app and CLI that gives you the display controls macOS hides: real DDC
brightness, contrast, volume and input switching, sharp HiDPI scaling on any monitor,
virtual displays, colour profiles, Night Shift/True Tone, presets, layout, hotkeys, and a
scriptable interface. No license key, no trial, no Pro tier, no telemetry.

> Nits is an independent project. It is not affiliated with BetterDisplay, Crisp,
> MonitorControl or Lunar.

## Status

This is **0.3.0**, a complete working foundation with the everyday features in place.
The architecture is built for the rest of the BetterDisplay feature list; see
[Roadmap](#roadmap) for what is deliberately not here yet.

Built and tested on macOS 27.2 (Apple Silicon). Deployment target: macOS 14.
It also supports Intel Macs through the IOFramebuffer I2C path, though that path is
less battle-tested.

## Features

### Display control

- **Brightness** — Apple panels through DisplayServices, external monitors through DDC/CI,
  and automatic **software gamma fallback** when DDC fails, the monitor is in HDR mode,
  or the requested level is below 15% (hardware 15% × gamma below it).
- **Volume and mute** — DDC VCP 0x62 with the low-byte max fix for buggy firmware,
  zero-volume mute fallback, and forced support for monitors that write but never read.
- **Contrast and RGB gain** — DDC VCP 0x12 / 0x16 / 0x18 / 0x1A, plus software contrast.
- **Input switching** — reads the monitor's MCCS capabilities and switches VCP 0x60.
- **Power** — DDC VCP 0xD6 on/off, and DDC audio mute 0x8D.
- **Image adjustment** — gamma, contrast, gain, colour temperature, per-channel gamma and
  gain, inversion and quantization, composed into one transfer table.
- **Extra brightness** — lifts external panels past 100% through the gamma table.
- **HDR software dimming** — routes brightness through gamma on monitors that silently
  discard DDC writes in HDR mode.
- **Monitor volume keys follow the pointer** — optional media-key interception.

### Resolution and layout

- Full mode list with HiDPI and refresh-rate selection, searchable from the panel.
- **HiDPI twin toggle** at the current size.
- **HiDPI override installer**, including a dense 16-point **smooth-scaling ladder**
  (one administrator prompt; modes enumerate after a soft reconnect).
- Rotation, main-display switching, mirroring / unmirroring.
- **Visual arrangement canvas** — drag displays to arrange them, with live edge/centre
  snapping guides and double-click-to-make-main.
- **Virtual displays** — create 1x or HiDPI virtual screens with a chosen size and
  refresh rate; optional auto-create at launch; managed from Settings or the CLI.
- **Disconnect / reconnect** physical displays on Apple Silicon, with a hard
  "never leave zero active displays" guard and a DDC hold around the WindowServer call.
- Sleep/wake mode restore, matched by attributes (never by volatile mode IDs).

### Colour and screen effects

- **ICC colour profiles** per display, with safe-profile filtering.
- **Night Shift** and **True Tone** toggles through CoreBrightness.
- Software gamma, contrast, gain, temperature, inversion and quantization.
- **EDID read/export**, plus **EDID override writing** (preserving an installed HiDPI
  ladder) with validation before a privileged write.

### Windows

- **Menu bar panel** for quick adjustments, and a **sidebar window** (panel → sidebar button, or
  right-click the menu bar icon → Open Nits Window) with every display and Settings.

### Presets, keys and integration

- Presets capture resolution, brightness, volume, contrast, input, image adjustment,
  layout, connection state and HDR routing, with an icon and a global shortcut.
- **Display groups** synchronize brightness, volume, image adjustment, input and logical
  resolution across selected displays.
- **Per-display event actions** run a preset, URL or shell command on connect, disconnect,
  sleep or wake.
- **Default resolution** per display, re-applied when it connects.
- Global shortcuts via Carbon (no Accessibility permission).
- OSD HUD with brightness/volume, including **estimated nits** where the display reports
  a luminance ceiling.
- Custom display names, EDID read/export, diagnostics report.
- Launch at login, keep awake, Dark Mode toggle.
- Screen effects: Night Shift and True Tone, where the hardware supports them.
- **CLI**: `nitsctl` with machine-readable JSON output.
- **URL scheme**: `nits://brightness?value=40`, `nits://preset/Work`, and more.
- **Local control socket** so the CLI can drive a running app (keep awake, apply preset,
  reload UI) without a second instance.
- Concurrency-safe config in `~/Library/Application Support/Nits/config.json`, with
  atomic writes and corrupt-file preservation.

## Build

No Xcode required — Apple Command Line Tools are enough.

```sh
make build          # debug build of all targets
make test           # self-test runner (111+ checks)
make check          # tests + release build
make app            # assemble dist/Nits.app and ad-hoc sign it
make run            # build and open the app
```

The app bundle is assembled by `scripts/build-app.sh`. The repository intentionally uses
SwiftPM instead of an `.xcodeproj`: it builds with a stock Command Line Tools install and
keeps CI trivial.

### Install

```sh
make install        # copy Nits.app to /Applications
make install-cli    # symlink nitsctl into ~/.local/bin
```

The app is a menu bar app (`LSUIElement`); look for the sun icon in the menu bar.
Open Settings from the gear at the bottom of the panel.

### Tests

`Tests/NitsSelfTest` is a normal executable with a tiny harness, because a stock
Command Line Tools install ships neither XCTest nor the Swift Testing macro plugin.
It covers DDC framing and reply validation, capabilities parsing, DDC pairing, mode
matching, gamma math, brightness routing, volume math, HiDPI planning, config
round-tripping and preset mode specs.

```sh
swift run NitsSelfTest
```

## CLI

```sh
nitsctl list
nitsctl --display 2 brightness 45
nitsctl --display studio volume +5
nitsctl input --display 2 list
nitsctl mode set 2560x1440@120 hidpi --display 2
nitsctl preset capture Work --icon briefcase.fill
nitsctl preset apply Work
nitsctl profile list --display 2
nitsctl profile set "Display P3" --display 2
nitsctl edid --display 2 --export monitor.edid
nitsctl edid override monitor.edid --display 2
nitsctl virtual create 2560x1440 "Studio" --refresh 60
nitsctl mode scale up
nitsctl overlay on -d builtin   # 0% brightness becomes true black
nitsctl group create Desk builtin 2 --sync brightness,image
nitsctl action set connect preset "Work" --display 2
nitsctl system nightshift on
nitsctl doctor
nitsctl watch --json
```

Display selectors accept `main`, `builtin`, `external`, `all`, a numeric CGDirectDisplayID,
a UUID prefix, or a name substring. See `nitsctl help` for the full list.

## URL scheme

```sh
open "nits://brightness?value=40&display=main"
open "nits://input?value=hdmi1&display=2"
open "nits://preset/Work"
open "nits://mode?width=2560&height=1440&refresh=120&hidpi=1"
open "nits://toggle-hidpi"
```

## Permissions

| Permission | Needed for | Without it |
| --- | --- | --- |
| Accessibility | hardware brightness / volume keys | custom global shortcuts still work |
| Automation (System Events) | Dark Mode toggle | the rest of the app is unaffected |
| Administrator (one prompt) | HiDPI override install | everything else works |

No permission is required for the menu bar panel, DDC, presets, CLI or URL scheme.

## How it stays stable

The DDC layer is the part that usually breaks display utilities. Nits encodes the
lessons from field debugging:

- one serial queue per display, so one wedged channel cannot stall another;
- one channel map built by **CoreDisplay location → framebuffer → DCPAVServiceProxy**
  (not by guessing from traversal order);
- detection of **MCDP29xx** HDMI controllers, which need chip address `0xB7`
  instead of `0x37`;
- **double-send** of Get/Set VCP requests for panels that ACK the first packet and
  only serve the second;
- every reply validated by header **and checksum**; a stale or NULL frame is rejected;
- read quarantine after repeated failures, immediate quarantine for a deaf channel;
- a 5-second value cache and latest-wins write pumps with a 50 ms pacing floor;
- full channel-map flush on every display reconfiguration (macOS reassigns IDs);
- a DDC hold around every display enable/disable, because WindowServer otherwise waits
  behind an in-flight I2C read and can freeze the whole Mac;
- every WindowServer transaction runs off-main with a 10-second timeout; connect/disconnect
  is verified by enumeration, never by the transaction's own return value.

More detail: [docs/DDC-FIELD-NOTES.md](docs/DDC-FIELD-NOTES.md).

## Roadmap

Implemented now: the everyday free feature set above, plus the arrangement canvas,
virtual displays, ICC profile switching, Night Shift/True Tone, EDID override writing,
display groups, per-display event actions, default resolutions and nits in the OSD.

Next (in rough order):

1. Resolution slider, custom timing/mode editing and true native-resolution overrides.
2. Overlay dimming and true black.
3. HTTP interface and macOS Shortcuts / App Intents.
4. Color mode selection, automatic SDR/HDR profile switching and forced HDR.
5. Input customization and configuration/layout protection.
6. Virtual-screen association/aspect matching and custom virtual configurations.
7. PIP / window capture / streaming / video filters.
8. TV/AVR control (LG webOS, Samsung Tizen, Philips, Yamaha) and HDMI-CEC.
9. 3D LUTs and compositor filters; true EDR/Metal HDR brightness boost.
10. Audio processing and user-defined DDC controls in the UI.

The core is split so each of these is a new controller, not a rewrite. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the full
[feature gap analysis](docs/FEATURE-GAPS.md) against BetterDisplay’s current list.

## Layout

```
Sources/NitsCore/        DDC, displays, controls, presets, config, CLI-facing runtime
Sources/NitsPrivate/     Objective-C shim for CGVirtualDisplay
Sources/NitsApp/         AppKit menu bar app, arrangement canvas, OSD, control socket
Sources/nitsctl/         command-line interface
Tests/NitsSelfTest/      dependency-free self-test runner
scripts/build-app.sh     bundle assembly without Xcode
docs/                    architecture, DDC field notes, roadmap
```

## License

MIT. See [LICENSE](LICENSE).

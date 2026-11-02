# Architecture

Nits is four SwiftPM targets over one shared core:

```
NitsCore     library   hardware, controls, presets, config, runtime facade
NitsPrivate  ObjC      CGVirtualDisplay shim (runtime lookup, nothing private linked)
NitsApp      exe       AppKit menu bar panel, arrangement, settings, OSD, control socket
nitsctl      exe       command-line interface
```

`NitsSelfTest` is a fifth executable target used as the test suite (see README).

## Why SwiftPM and AppKit

A stock macOS Command Line Tools install cannot build SwiftUI (the SwiftUI macro plugin
ships with Xcode) and does not include XCTest. Using AppKit + SwiftPM means:

- `swift build` works on a clean Mac with no Xcode;
- `make app` assembles and ad-hoc signs a real `.app` by hand;
- the same core powers both the app and the CLI;
- tests run as a normal executable, independent of Xcode.

## Layers

### Support

- `NitsLog` — `os.Logger` categories plus an in-memory ring for diagnostics.
- `withTimeout` — bounds blocking WindowServer calls that have no cancellation.
- `LatestValuePump` — actor implementing latest-wins hardware writes with a pacing floor.
- `ConfigStore` — atomic JSON, corrupt-file preservation, revision-aware reload.
- `ControlClient` — one-line client for the app's Unix socket.
- `NitsPaths` — Application Support paths.

### DDC

- `DDCPacket` — pure framing, checksums, reply validation.
- `DDCCapabilities` — MCCS capabilities parsing, chunk framing.
- `DDCPairing` — pure location/serial/model/traversal pairing.
- `IOAVServiceProvider` — Apple Silicon channel discovery and I2C, including MCDP29xx.
- `IntelTransport` — IOFramebuffer I2C fallback.
- `DDCEngine` — per-display queues, cache, retries, quarantine, capabilities, holds.

**Invariants**

1. Every DDC byte is validated by header and checksum before use.
2. Each display has its own serial queue.
3. Any display reconfiguration flushes the whole channel map and read quarantine.
4. Display enable/disable is wrapped in a DDC hold.
5. No CoreGraphics/WindowServer call runs on the main thread without a timeout.

### Displays

- `DisplayCatalog` — snapshots: stable UUID, identity, name, native/panel size,
  connection, native-brightness capability.
- `DisplayModeQuery` / `ResolutionController` — mode list, apply, HiDPI twin, rotation,
  sleep/wake restore, hidden-mode fallback.
- `DisplayMonitor` — debounced CG reconfiguration notifications.
- `HiDPIOverride` — scale-resolutions plist planning and privileged install.
- `ArrangementController` — origins, main display, mirroring (commits `.permanently`).
- `DisconnectController` — SkyLight enable bit with last-screen guard and DDC hold.
- `NativeBrightness` — optional DisplayServices symbols.
- `EDIDService` — EDID read/export and field decoding.
- `EDIDOverride` — validated privileged override writer that preserves HiDPI keys.
- `ColorProfileService` — ColorSync ICC enumeration/assignment and safety filtering.
- `VirtualDisplayService` — `CGVirtualDisplay` lifecycle, persistence and auto-create.
- `DisplayLuminanceService` — built-in/EDID nominal nits for the OSD and comparisons.
- `PrivateDisplayAPIs` — dynamically resolved SkyLight/CGS symbols.

### Controls

- `BrightnessController` — native / DDC / software routing, coalesced writes,
  15% gamma blend, three-failure software latch, extra brightness.
- `GammaEngine` + `GammaMath` — one transfer table per display.
- `VolumeController` — VCP 0x62, max fix, mute, forced support.
- `HardwareControls` — contrast, RGB gain, power, mute.
- `InputController` + `InputSource` — capabilities-driven input switching.
- `CoreBrightness` — optional Night Shift / True Tone through CoreBrightness clients.

### Runtime

`NitsRuntime` is the composition root:

- owns every controller;
- applies persisted settings when a display appears;
- invalidates the DDC map and per-display state on reconfiguration;
- persists settings, connection records, presets, groups and event actions;
- applies group synchronization after local changes;
- runs connect/disconnect/sleep/wake actions with a recursion guard;
- exposes high-level operations used by both front ends;
- registers default global hotkey actions.

`DisplayState` is the serializable snapshot the app and CLI both consume.

### Front ends

- `MenuPanelViewController` — fixed header, presets bar, scrollable display cards,
  dynamic height, status banner, footer.
- `ArrangementWindowController` — drag canvas with snapping guides and main switching.
- `DisplayCardView` — brightness/volume sliders, input menu, color profile, HiDPI,
  expandable detail (resolution, contrast, image adjustment, HDR, extra, disconnect).
- `SettingsViewController` — General/Shortcuts/Groups/Virtual/Advanced/About, hotkey
  recorder, screen effects, virtual displays, diagnostics and recovery.
- `EventActionsWindowController` — per-display preset/URL/script event editor.
- `OSDController` — borderless AppKit HUD on the pointer's screen.
- `MediaKeyTap` — optional CGEventTap for hardware keys.
- `ControlSocketServer` — one-line commands from `nitsctl`, including virtual-display
  creation/removal and live reload (chmod 600, one user only).
- `URLHandler` — `nits://` commands, including cold-launch queueing.

## Threading

- The UI is main-actor.
- DDC runs on one serial `DispatchQueue` per display.
- Controller state is protected with `NSLock`; pumps are actors.
- WindowServer transactions run on a global queue inside `withTimeout`.
- Config writes are debounced on a utility queue and atomic.

## Persistence

`~/Library/Application Support/Nits/config.json`:

- `general` — OSD, steps, sync, hotkeys, launch/keep-awake, media keys.
- `displaySettings[uuid]` — brightness, volume, contrast, gamma, last input, custom name,
  software factor, HDR/extra flags, forced volume.
- `presets` — full display entries with optional attributes.
- `disconnected` — reconnect records by UUID.
- `groups` — member UUIDs and per-feature sync flags.
- `displaySettings[uuid].eventActions` — connect/disconnect/sleep/wake actions.
- `displaySettings[uuid].defaultMode` — resolution re-applied on connect.

Everything per display is keyed by the stable ColorSync UUID, never by
`CGDirectDisplayID`.

## Adding features

Each roadmap item is designed as a controller + runtime methods + CLI/UI surface:

- virtual displays: a `VirtualDisplayController` owning `CGVirtualDisplay`;
- PIP/stream: an overlay/window controller on top of that;
- colour profiles: ColorSync controller;
- TV/AVR: a device protocol module with discovery and a VCP-like command model;
- HTTP/App Intents: a transport module over the same runtime operations.

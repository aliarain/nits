# Feature gaps vs BetterDisplay

Reference: [BetterDisplay free and pro features](https://betterdisplay.pro/guide/licensing/free-and-pro-features/)
(read 2026-11-02). This is a working gap list for Nits 0.3.0, not a promise of parity.
“Partial” means a working foundation exists but a meaningful part of the feature is absent.

## Already covered

For context, Nits already has: menu bar GUI; native and DDC brightness; software gamma
dimming; combined hardware/software dimming; DDC contrast, volume, gain, input and power;
capability detection; display mode and refresh selectors; HiDPI twin and HiDPI override
(smooth ladder); rotation; mirroring; main display; a **visual arrangement canvas** with
edge/centre snapping; **basic virtual displays** (size, refresh, HiDPI, auto-create);
physical disconnect/reconnect; display names; **EDID read/export and EDID override
writing**; **ICC color-profile switching**, **Night Shift** and **True Tone**; presets
with hotkeys; **display groups** (brightness, volume, image, input, logical resolution);
**per-display connect/disconnect/sleep/wake actions**; default resolutions; estimated nits
in the OSD; native media keys; global shortcuts; OSD; CLI; URL scheme; control socket;
doctor report; keep awake; launch at login; Dark Mode; sleep/wake mode restore.

## Missing or partial features

### Brightness and dimming

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Dimming to black | Partial | Gamma floor is 0.01 and DDC floor is 15%, so 0% is near-black, not true black. Needs a real blackout overlay or gamma floor 0 plus a safe recovery path. |
| Software dimming through overlays | Missing | We only use color tables. Needs a transparent overlay window (or Metal layer) for displays/HDR where the table is unsuitable. |
| Color-table XDR/HDR brightness upscaling | Missing | We lift gamma for “extra brightness”, but do not drive the panel’s XDR/HDR color table or EDR headroom. Needs CoreDisplay/CoreBrightness color-table work. |
| Metal XDR/HDR brightness upscaling | Missing | Needs a Metal compositor overlay that adds luminance above SDR, per display, with HDR video handling. |
| Direct XDR brightness upscaling | Missing | Needs the private XDR brightness path on supported Apple Silicon configurations. |
| Brightness in nits on the OSD | Done | CoreDisplay/EDID luminance ceilings drive an estimated “% · ~nits” line in the OSD. |
| HDR extra-brightness calibration | Missing | Needs a calibration model and headroom control, not a gamma gain. |
| Brightness upscaling for third-party HDR displays | Missing | Same as above; requires HDR metadata and an overlay/color-table path. |
| Prevent sleep only while a specific display is connected | Partial | We have a global keep-awake switch. Needs a per-display conditional assertion with reconnect tracking. |

### Color and HDR

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Software color temperature | Done (gamma) | We implement it through the transfer table; BetterDisplay marks it Pro, ours is free. |
| Advanced software color adjustments | Partial | Gamma, contrast, gain, temperature, per-channel gain/gamma, inversion and quantization exist. Missing color matrices, curves and arbitrary LUTs. |
| Custom 3D LUTs | Missing | Needs LUT parsing, a Metal/GLSL compositor, per-display assignment and PIP/stream application. |
| Color profile selection | Done | ColorSync enumeration and custom-profile assignment, filtered to safe RGB display profiles. |
| XDR reference preset selection | Missing | Needs the reference-mode enumeration/apply path (ICC profiles exist). |
| Automatic color profile switching SDR ↔ HDR | Missing | Needs HDR-state observation and profile rules. |
| Forced HDR switching | Missing | Needs the private HDR/CGS path and mode capability checks. |
| Color mode selection (Apple Silicon) | Missing | Needs the color-mode enumeration and apply APIs. |
| Night Shift | Done | CoreBrightness `CBBlueLightClient`, with availability fallback. |
| Night Shift for TVs | Missing | Depends on TV control. |
| True Tone | Done | CoreBrightness `CBTrueToneClient`, hardware-dependent. |
| Per-display ambient light readings | Missing | Needs the ambient-light sensor APIs/IOHID path and per-display mapping. |
| Expanded compositor filters (sharpening, geometry, advanced color) | Missing | Needs a real compositor pipeline; see PIP/stream/filters. |

### Resolution, scaling and virtual screens

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Custom scaled-resolution editing | Partial | We generate coarse/dense HiDPI overrides. No editor for arbitrary custom modes/timings or importing custom sets. |
| Flexible HiDPI scaling | Partial | HiDPI twins and a dense 16-point smooth ladder exist. No per-display “looks like” slider with live switching, and very wide panels past the backing cap need the mirrored-virtual trick. |
| Resolution slider | Partial | A "looks like" scale slider (card detail) and `nitsctl mode scale` step through one rung per logical size at the current scaling. Missing: live preview before commit and a custom-timing editor. |
| Native/default resolution overrides | Partial | “Set current resolution as default” persists and re-applies a mode on connect; there is no true native-mode override or custom timing. |
| Additional and NTSC refresh rates | Missing | Needs custom timing/mode injection on supported Apple Silicon configurations. |
| Virtual screen creation | Done | `CGVirtualDisplay` lifecycle through an Objective-C shim, size/refresh/HiDPI, persistence and auto-create. |
| Virtual screen association / aspect matching | Missing | Needs matching virtual screens to physical displays and layout rules. |
| Custom virtual screen configurations | Partial | Name, size, refresh, HiDPI and auto-create exist; no arbitrary mode/timing sets or per-display association. |
| HDR and high-refresh virtual screens | Partial | Choose a refresh rate; HDR virtual descriptors are not implemented. |
| DisplayLink DDC and color control | Missing | Needs the DisplayLink transport/color path; current DDC is DCP/IOFramebuffer only. |
| DDC input customization | Partial | We read MCCS inputs and switch them. No user-defined input names/values or per-display input lists. |

### Layout, mirroring and protection

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Visual display arrangement with on-screen guides | Done | Drag canvas with edge/centre snapping guides and double-click-to-make-main. Grid-snap presets/edge crossing are not implemented. |
| Mirroring configuration and protection | Partial | Mirror/unmirror exists. No protection that re-applies a mirror after reconnect or OS changes. |
| Display configuration protection | Missing | Needs a guard that restores mode/refresh/HDR/arrangement when something changes them. |
| Adaptive layout protection / advanced layout management | Missing | Needs layout snapshots, change detection and re-apply policies. |
| Per-display actions on connect/disconnect/sleep/wake | Done | Preset, URL or shell command per display and event; configured from the card menu or CLI. |
| Sidebar layout | Missing | Panel is popover-only. Needs a docked/sidebar window mode. |
| Optional menu bar right-click actions | Done | Right-click quick menu with presets/system toggles exists. |

### PIP, streaming and video filters

All missing:

- picture-in-picture for physical displays and virtual screens;
- window and window-group capture;
- full-screen local streaming;
- target frame-rate controls;
- compositor rendering for Video Filter Windows;
- PIP/stream stretching and positioning;
- PIP/stream rotation and portrait Sidecar;
- PIP/stream cropping;
- teleprompter mode through flipping;
- cursor exclusion from stream targets;
- full-screen video filters.

Needs a compositor layer (Metal/AVFoundation/ScreenCaptureKit), a window model, and virtual
display/scaling prerequisites.

### TV, AVR and HDMI-CEC

All missing:

- HDMI-CEC TV control (including CLI);
- LG webOS;
- Samsung Tizen;
- Philips Android TV;
- Yamaha AVR.

Needs network discovery, per-vendor protocols, credentials/tokens, CEC transport and a
shared “external device” abstraction so they appear alongside displays.

### Audio

Missing beyond monitor DDC volume/mute:

- software audio volume and mute;
- audio gain, bass, treble, meters;
- combined volume control;
- balance, channel trims, stereo width, mono, channel swapping, polarity;
- 10-band EQ, bass boost, loudness compensation, frequency filters;
- compressor, noise gate, soft clipping.

Needs a CoreAudio processing graph and per-device routing/UI.

### Groups and synchronization

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Custom display groups | Done | Group editor with members and brightness/volume/image/input/resolution sync. |
| Basic brightness syncing | Done | Legacy global sync plus per-group sync. |
| Advanced brightness/image-adjustment syncing | Partial | Gamma/contrast mirror across groups; no selective per-channel rules or filter sync. |
| Normalized brightness syncing in nits | Missing | Needs luminance estimates per display and a target-nits model. |
| Resolution syncing and UI scale matching | Partial | Same logical mode is applied to group members; no UI-scale matching across unlike panels. |
| Expanded filter syncing | Missing | Depends on filters. |

### Integration and automation

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Command-line interface | Done | `nitsctl` with JSON output. |
| Custom URL scheme | Done | `nits://` commands. |
| HTTP interface | Missing | Needs a loopback-only server with authentication/token and a small REST surface. |
| macOS Shortcuts / App Intents | Missing | Needs Intents definitions, app bundle metadata and action coverage. |
| Built-in console with CLI access and optional app logs | Partial | We have `doctor`, a unified-log view in settings and a log ring, but no interactive in-app console or live log streamer. |
| Standard integration via scripts, URLs, notifications | Partial | Scripts and URLs work. No distributed/local notifications emitted for display changes or control events. |
| User-defined custom integration and DDC controls | Partial | Raw VCP get/set exists in the CLI. No UI-defined controls, named actions or per-display custom buttons. |
| External HUD / notch-app integration | Missing | No external HUD feed or notch app integration. |
| Auto-update | Missing | No Sparkle/update feed. |

### Diagnostics

| BetterDisplay feature | Nits | What is missing / what it needs |
| --- | --- | --- |
| Expanded display information and diagnostic reports | Partial | We report identity, modes, DDC channel, VCP probes, raw replies, capabilities, EDID, private-API availability and recent log. Missing DPCD, DSC, HDMI-CEC and Apple brightness reports, plus a dedicated display-information export. |
| EDID retrieval and export | Done | `nitsctl edid --export`. |
| EDID overrides | Done | Validated privileged write that preserves the HiDPI ladder; CLI install/restore. |

### Platform and product

| Feature | Nits | What is missing |
| --- | --- | --- |
| Localization | Missing | English only. BetterDisplay ships 38 language/regional variants with RTL. |
| Onboarding / first-run setup | Missing | No guided setup, permission walkthrough or sample preset. |
| Native/traditional OSD option | Partial | We ship one custom HUD. No native OSD option and no styling presets. |
| Advanced custom keyboard shortcuts | Partial | Global actions and preset shortcuts exist. No per-display targeting, multi-step actions, or pointer/all/specific routing per shortcut. |
| DDC on Intel | Partial | Implemented and compiles, but not field-tested on Intel hardware. |
| DDC through built-in HDMI (M1 / entry M2 mini / 2018 Intel mini) | Partial | MCDP29xx chip-address detection is implemented; the specific machines are untested. |

## Suggested build order

### Next (highest user value per unit of work)

1. **Resolution slider + custom mode/timing editor + true native-resolution overrides**.
2. **Overlay dimming + true black** (nits OSD is done).
3. **HTTP interface + App Intents** over the existing runtime operations.
4. **Color mode selection, automatic SDR/HDR profile switching, forced HDR**.
5. **Input customization + configuration/layout protection**.
6. **Virtual-screen association/aspect matching and custom virtual configurations**.
7. **Nits-normalized brightness sync, UI-scale matching, filter sync**.

### Then

8. PIP / window capture / full-screen streaming / video filter windows.
9. 3D LUTs and compositor filters (sharpening, geometry, advanced color).
10. XDR/HDR upscaling (color table, Metal overlay, direct XDR).
11. TV/AVR/HDMI-CEC control.
12. Audio processing (software audio, gain, EQ, compressor).
13. Ambient light, DisplayLink, notch/HUD integration.
14. Localization, onboarding, auto-update.

### Architecture note

Each item maps to a new controller plus runtime methods and CLI/UI surfaces; none require
rewriting the DDC or display core. The compositor items (PIP, filters, LUTs, Metal XDR
upscaling) share one new layer and should be designed together.

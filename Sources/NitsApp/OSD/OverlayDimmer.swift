import AppKit
import CoreGraphics

/// Draws a click-through black window over a display. The opacity is the dim amount, so
/// full opacity is true black on any panel, and it composes with the transfer table
/// instead of replacing it. The windows are never interactive, so the menu bar, hotkeys
/// and media keys keep working at 0%, and they disappear with the process.
@MainActor
final class OverlayDimmer {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func set(opacity: Double, for displayID: CGDirectDisplayID) {
        guard opacity > 0.001 else {
            remove(displayID)
            return
        }
        guard let screen = Self.screen(for: displayID) else {
            remove(displayID)
            return
        }
        let window = windows[displayID] ?? makeWindow(for: displayID, screen: screen)
        window.backgroundColor = NSColor.black.withAlphaComponent(min(1, opacity))
        window.orderFrontRegardless()
    }

    func removeAll() {
        for id in Array(windows.keys) { remove(id) }
    }

    private func remove(_ displayID: CGDirectDisplayID) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
    }

    private func makeWindow(for displayID: CGDirectDisplayID, screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        windows[displayID] = window
        return window
    }

    private func relayout() {
        for (id, window) in windows {
            if let screen = Self.screen(for: id) {
                window.setFrame(screen.frame, display: true)
            } else {
                remove(id)
            }
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

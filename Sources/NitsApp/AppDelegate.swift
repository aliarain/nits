import AppKit
import NitsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: NitsRuntime!
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsController: SettingsWindowController?
    private var observers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var controlServer: ControlSocketServer?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = NitsRuntime()
        model = AppModel(runtime: runtime)
        runtime.startMonitoring()
        model.start()
        controlServer = ControlSocketServer(model: model)
        controlServer?.start()

        configureStatusItem()
        configurePopover()
        observeSystem()

        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued {
            URLHandler.handle(url, model: model)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.model.refreshAll(seedHardware: true)
        }
        if ProcessInfo.processInfo.environment["NITS_SHOW_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.togglePopover()
            }
        }
        if let path = ProcessInfo.processInfo.environment["NITS_SNAPSHOT_PATH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let view = self?.popover.contentViewController?.view,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        if ProcessInfo.processInfo.environment["NITS_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openSettings()
            }
            if let path = ProcessInfo.processInfo.environment["NITS_SETTINGS_SNAPSHOT_PATH"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                    guard let view = self?.settingsController?.snapshotView(),
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                    else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        model.stopMediaKeys()
        runtime.shutdown()
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // LaunchServices can deliver the opening URL before applicationDidFinishLaunching.
        guard let model else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            URLHandler.handle(url, model: model)
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "sun.max.fill",
            accessibilityDescription: "Nits"
        )
        button.image?.isTemplate = true
        button.toolTip = "Nits — display control"
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
            return
        }
        togglePopover()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = MenuPanelViewController(
            model: model,
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApp.terminate(nil) }
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        model.refreshAll(seedHardware: false)
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Nits", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for preset in model.presets.prefix(8) {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(applyPresetFromMenu(_:)),
                keyEquivalent: ""
            )
            item.representedObject = preset.id.uuidString
            item.target = self
            menu.addItem(item)
        }
        if !model.presets.isEmpty { menu.addItem(.separator()) }

        let awake = NSMenuItem(
            title: "Keep Awake",
            action: #selector(toggleKeepAwakeFromMenu),
            keyEquivalent: ""
        )
        awake.state = model.keepAwake ? .on : .off
        awake.target = self
        menu.addItem(awake)

        let dark = NSMenuItem(
            title: "Dark Mode",
            action: #selector(toggleDarkModeFromMenu),
            keyEquivalent: ""
        )
        dark.state = model.isDarkMode ? .on : .off
        dark.target = self
        menu.addItem(dark)

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Nits", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func applyPresetFromMenu(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        model.applyPreset(id: id)
    }

    @objc private func toggleKeepAwakeFromMenu() {
        model.setKeepAwake(!model.keepAwake)
    }

    @objc private func toggleDarkModeFromMenu() {
        model.toggleDarkMode()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model)
        }
        settingsController?.show()
    }

    // MARK: - Notifications

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runtime.snapshotForSleep() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.runtime.handleWake()
                self.model.refreshAll(seedHardware: true)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runtime.handleWake() }
        })
    }
}

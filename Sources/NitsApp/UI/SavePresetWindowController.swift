import AppKit
import NitsCore

@MainActor
final class SavePresetWindowController: NSWindowController {
    private let model: AppModel
    private let nameField = NSTextField()
    private let iconPopup = NSPopUpButton()
    private var hotkey: HotkeyBinding?
    private var recorder: HotkeyRecorderControl?

    private let icons: [(name: String, symbol: String)] = [
        ("Display", "display"),
        ("Laptop", "laptopcomputer"),
        ("Bright", "sun.max.fill"),
        ("Night", "moon.fill"),
        ("Game", "gamecontroller.fill"),
        ("Movie", "film.fill"),
        ("Work", "briefcase.fill"),
        ("Home", "house.fill"),
        ("Creative", "paintpalette.fill"),
        ("Camera", "camera.fill"),
    ]

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Save Preset"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo parent: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nameField)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let title = Theme.label("Save preset", size: 14, weight: .semibold)
        let subtitle = Theme.label(
            "Captures resolution, brightness, volume, input, image adjustment and layout.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 2
        )

        nameField.placeholderString = "Name (for example: Work)"
        nameField.translatesAutoresizingMaskIntoConstraints = false

        iconPopup.translatesAutoresizingMaskIntoConstraints = false
        for icon in icons {
            iconPopup.addItem(withTitle: icon.name)
            iconPopup.lastItem?.image = Theme.symbol(icon.symbol, size: 12)
        }

        let recorder = HotkeyRecorderControl(binding: nil) { [weak self] binding in
            self?.hotkey = binding
            self?.window?.makeFirstResponder(nil)
        }
        self.recorder = recorder

        let nameRow = Theme.horizontal([Theme.label("Name", size: 11), nameField], spacing: 10)
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let iconRow = Theme.horizontal([Theme.label("Icon", size: 11), iconPopup, Theme.flexibleSpace()], spacing: 10)
        let keyRow = Theme.horizontal(
            [Theme.label("Shortcut", size: 11), Theme.flexibleSpace(), recorder],
            spacing: 10
        )

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(savePressed))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let buttons = Theme.horizontal([Theme.flexibleSpace(), cancel, save], spacing: 8)

        let stack = Theme.vertical([title, subtitle, nameRow, iconRow, keyRow, buttons], spacing: 12)
        content.addSubview(stack)
        Theme.pin(stack, to: content, insets: NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18))
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        iconRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc private func savePressed() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(nameField)
            return
        }
        let index = max(0, iconPopup.indexOfSelectedItem)
        let icon = icons.indices.contains(index) ? icons[index].symbol : "display"
        model.savePreset(name: name, icon: icon, hotkey: hotkey)
        window?.close()
    }

    @objc private func cancelPressed() {
        window?.close()
    }
}

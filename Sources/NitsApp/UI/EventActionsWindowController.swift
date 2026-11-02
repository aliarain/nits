import AppKit
import NitsCore

@MainActor
final class EventActionsWindowController: NSWindowController {
    private let model: AppModel
    private let display: DisplaySnapshot
    private var kindPopups: [DisplayEventAction.Event: NSPopUpButton] = [:]
    private var valueFields: [DisplayEventAction.Event: NSTextField] = [:]

    private let kinds: [DisplayEventAction.Kind?] = [nil, .preset, .url, .script]
    private let kindNames = ["None", "Preset", "URL", "Script"]

    init(model: AppModel, display: DisplaySnapshot) {
        self.model = model
        self.display = display
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Actions — \(display.name)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let note = Theme.label(
            "Run a preset, open a URL (including nits:// links), or run a shell command when this display connects, disconnects, sleeps or wakes.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 3
        )

        var rows: [NSView] = [note]
        for event in DisplayEventAction.Event.allCases {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: kindNames)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 10)
            popup.tag = DisplayEventAction.Event.allCases.firstIndex(of: event) ?? 0
            popup.target = self
            popup.action = #selector(kindChanged(_:))

            let field = NSTextField()
            field.controlSize = .small
            field.font = .systemFont(ofSize: 10)
            field.placeholderString = "value"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

            if let existing = model.runtime.eventAction(for: display, event: event) {
                if let index = kinds.firstIndex(where: { $0 == existing.kind }) {
                    popup.selectItem(at: index)
                }
                field.stringValue = existing.value
                field.isEnabled = true
            } else {
                popup.selectItem(at: 0)
                field.isEnabled = false
            }

            kindPopups[event] = popup
            valueFields[event] = field
            let row = Theme.horizontal(
                [Theme.label(event.label, size: 11, weight: .medium), popup, field],
                spacing: 8
            )
            rows.append(row)
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save", target: self, action: #selector(savePressed))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        rows.append(Theme.horizontal([Theme.flexibleSpace(), cancel, save], spacing: 8))

        let stack = Theme.vertical(rows, spacing: 10, alignment: .leading)
        content.addSubview(stack)
        Theme.pin(stack, to: content, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard let event = eventFor(tag: sender.tag) else { return }
        let kind = kinds[safe: sender.indexOfSelectedItem] ?? nil
        valueFields[event]?.isEnabled = kind != nil
        switch kind {
        case .preset: valueFields[event]?.placeholderString = "preset name or UUID"
        case .url: valueFields[event]?.placeholderString = "https://… or nits://…"
        case .script: valueFields[event]?.placeholderString = "shell command"
        default: valueFields[event]?.placeholderString = "value"
        }
    }

    @objc private func savePressed() {
        for event in DisplayEventAction.Event.allCases {
            let index = kindPopups[event]?.indexOfSelectedItem ?? 0
            guard let kind = kinds[safe: index] ?? nil else {
                model.runtime.setEventAction(nil, for: display, event: event)
                continue
            }
            let value = valueFields[event]?.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                model.runtime.setEventAction(nil, for: display, event: event)
                continue
            }
            model.runtime.setEventAction(
                DisplayEventAction(event: event, kind: kind, value: value),
                for: display,
                event: event
            )
        }
        model.showStatus("Saved actions for \(display.name)")
        window?.close()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    private func eventFor(tag: Int) -> DisplayEventAction.Event? {
        DisplayEventAction.Event.allCases[safe: tag]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

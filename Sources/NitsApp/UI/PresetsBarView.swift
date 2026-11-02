import AppKit
import NitsCore

@MainActor
final class PresetsBarView: NSView {
    var onApply: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onSave: (() -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let title = Theme.label("PRESETS", size: 9, weight: .semibold, color: .tertiaryLabelColor)
        title.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPresets(_ presets: [DisplayPreset]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for preset in presets {
            let button = NSButton(title: preset.name, target: self, action: #selector(applyPreset(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            if let image = Theme.symbol(preset.icon, size: 10) {
                button.image = image
                button.imagePosition = .imageLeading
            }
            button.identifier = NSUserInterfaceItemIdentifier(preset.id.uuidString)
            button.toolTip = preset.hotkey.map { "Shortcut: \($0.label)" }

            let menu = NSMenu()
            let delete = NSMenuItem(title: "Delete", action: #selector(deletePreset(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = preset.id.uuidString
            menu.addItem(delete)
            button.menu = menu
            stack.addArrangedSubview(button)
        }

        let save = NSButton(title: "Save", target: self, action: #selector(savePreset))
        save.bezelStyle = .rounded
        save.controlSize = .small
        save.font = .systemFont(ofSize: 11, weight: .medium)
        save.image = Theme.symbol("plus", size: 9)
        save.imagePosition = .imageLeading
        if presets.isEmpty { save.toolTip = "Save the current setup as a preset" }
        stack.addArrangedSubview(save)
    }

    @objc private func applyPreset(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        onApply?(id)
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        onDelete?(id)
    }

    @objc private func savePreset() {
        onSave?()
    }
}

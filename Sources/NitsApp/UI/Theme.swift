import AppKit

enum Theme {
    static let cardRadius: CGFloat = 12
    static let panelWidth: CGFloat = 390

    static func label(
        _ text: String,
        size: CGFloat = 11,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        lines: Int = 1
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        field.maximumNumberOfLines = lines
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func symbol(_ name: String, size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    static func iconButton(
        _ symbolName: String,
        target: AnyObject?,
        action: Selector?,
        tooltip: String? = nil,
        size: CGFloat = 13
    ) -> NSButton {
        let button = NSButton()
        button.image = symbol(symbolName, size: size)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.target = target
        button.action = action
        button.toolTip = tooltip
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    static func horizontal(
        _ views: [NSView],
        spacing: CGFloat = 8,
        alignment: NSLayoutConstraint.Attribute = .centerY
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func vertical(
        _ views: [NSView],
        spacing: CGFloat = 8,
        alignment: NSLayoutConstraint.Attribute = .leading
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func flexibleSpace() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    @discardableResult
    static func pin(_ view: NSView, to parent: NSView, insets: NSEdgeInsets = NSEdgeInsets()) -> [NSLayoutConstraint] {
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    static func badge(_ text: String, color: NSColor) -> NSView {
        let field = label(text, size: 8, weight: .bold, color: color)
        field.alignment = .center
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 4
        container.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
        ])
        return container
    }
}

/// A flipped container so a scroll view starts at the top instead of the bottom.
final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = Theme.cardRadius
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        }
    }
}

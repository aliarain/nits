import AppKit

/// Borderless, click-through HUD drawn with AppKit. It follows the pointer's screen and
/// never becomes key, so it cannot steal focus from what the user is doing.
final class OSDController {
    static let shared = OSDController()

    private var panel: NSPanel?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var progress: OSDProgressView?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(
        icon: String,
        title: String,
        detail: String,
        fraction: Double,
        duration: TimeInterval = 1.2
    ) {
        let panel = ensurePanel()
        iconView?.image = Theme.symbol(icon, size: 21, weight: .medium)
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        progress?.fraction = min(1, max(0, fraction))
        progress?.needsDisplay = true

        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.completionHandler = { panel.orderOut(nil) }
                panel.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 78),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.contentView = effect

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let titleLabel = Theme.label("Brightness", size: 12, weight: .semibold, color: .white)
        let detailLabel = Theme.label("50%", size: 12, weight: .medium, color: NSColor.white.withAlphaComponent(0.75))
        detailLabel.alignment = .right
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let textRow = Theme.horizontal([titleLabel, Theme.flexibleSpace(), detailLabel], spacing: 8)
        let progress = OSDProgressView()
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let textColumn = Theme.vertical([textRow, progress], spacing: 7, alignment: .width)
        textRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true

        let row = Theme.horizontal([icon, textColumn], spacing: 12)
        effect.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: effect.topAnchor, constant: 15),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -15),
        ])

        self.panel = panel
        self.iconView = icon
        self.titleLabel = titleLabel
        self.detailLabel = detailLabel
        self.progress = progress
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let size = NSSize(width: 340, height: 78)
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 70
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

final class OSDProgressView: NSView {
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.18).setFill()
        track.fill()

        let width = max(2, bounds.width * CGFloat(min(1, max(0, fraction))))
        let fillRect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.92).setFill()
        fill.fill()
    }
}

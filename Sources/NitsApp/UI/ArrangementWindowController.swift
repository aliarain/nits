import AppKit
import CoreGraphics
import NitsCore

@MainActor
final class ArrangementWindowController: NSWindowController {
    private let canvas: ArrangementCanvasView

    init(model: AppModel) {
        self.canvas = ArrangementCanvasView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Arrange Displays"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        window.contentView = canvas
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo parent: NSWindow?) {
        canvas.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ArrangementItem {
    let id: UInt32
    let uuid: String
    let name: String
    let size: CGSize
    let isMain: Bool
    var origin: CGPoint
}

private struct ArrangementGuide {
    let vertical: Bool
    let position: CGFloat
}

@MainActor
final class ArrangementCanvasView: NSView {
    private let model: AppModel
    private var items: [ArrangementItem] = []
    private var selectedIndex: Int?
    private var dragIndex: Int?
    private var dragOffset: CGPoint = .zero
    private var guides: [ArrangementGuide] = []
    private var appliedOrigin: [UInt32: CGPoint] = [:]

    private var scale: CGFloat = 1
    private var layoutOrigin: CGPoint = .zero
    private var contentInset: CGFloat = 42

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        items = model.rows
            .filter { !$0.state.disconnected }
            .map { row in
                ArrangementItem(
                    id: row.display.id,
                    uuid: row.display.uuid,
                    name: row.display.name,
                    size: CGSize(
                        width: row.display.bounds.width,
                        height: row.display.bounds.height
                    ),
                    isMain: row.display.isMain,
                    origin: CGPoint(x: row.display.bounds.x, y: row.display.bounds.y)
                )
            }
        selectedIndex = nil
        dragIndex = nil
        guides = []
        updateLayout()
        needsDisplay = true
    }

    private func updateLayout() {
        guard !items.isEmpty else { return }
        let minX = items.map(\.origin.x).min() ?? 0
        let minY = items.map(\.origin.y).min() ?? 0
        let maxX = items.map { $0.origin.x + $0.size.width }.max() ?? 1
        let maxY = items.map { $0.origin.y + $0.size.height }.max() ?? 1

        let usable = CGSize(
            width: max(1, bounds.width - contentInset * 2),
            height: max(1, bounds.height - contentInset * 2 - 24)
        )
        let contentWidth = max(1, maxX - minX)
        let contentHeight = max(1, maxY - minY)
        scale = min(usable.width / contentWidth, usable.height / contentHeight, 1.4)
        scale = max(0.08, scale)

        let drawnWidth = contentWidth * scale
        let drawnHeight = contentHeight * scale
        layoutOrigin = CGPoint(
            x: contentInset + (usable.width - drawnWidth) / 2 - minX * scale,
            y: contentInset + (usable.height - drawnHeight) / 2 - minY * scale + 12
        )
    }

    private func canvasRect(for item: ArrangementItem) -> CGRect {
        CGRect(
            x: layoutOrigin.x + item.origin.x * scale,
            y: layoutOrigin.y + item.origin.y * scale,
            width: item.size.width * scale,
            height: item.size.height * scale
        ).integral
    }

    private func displayPoint(from canvasPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (canvasPoint.x - layoutOrigin.x) / scale,
            y: (canvasPoint.y - layoutOrigin.y) / scale
        )
    }

    // MARK: - Drawing

    override func layout() {
        super.layout()
        updateLayout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let title = "Drag to arrange · double-click a display to make it main"
        title.draw(
            at: NSPoint(x: 24, y: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        guard !items.isEmpty else {
            "No displays".draw(
                at: NSPoint(x: 24, y: 64),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            return
        }

        updateLayout()

        for guide in guides {
            let path = NSBezierPath()
            let accent = NSColor.controlAccentColor.withAlphaComponent(0.7)
            accent.setStroke()
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            if guide.vertical {
                path.move(to: NSPoint(x: guide.position, y: 34))
                path.line(to: NSPoint(x: guide.position, y: bounds.height - 20))
            } else {
                path.move(to: NSPoint(x: 20, y: guide.position))
                path.line(to: NSPoint(x: bounds.width - 20, y: guide.position))
            }
            path.stroke()
        }

        for (index, item) in items.enumerated() {
            let rect = canvasRect(for: item)
            let selected = index == selectedIndex
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)

            let fill = item.isMain
                ? NSColor.controlAccentColor.withAlphaComponent(selected ? 0.28 : 0.18)
                : NSColor.controlBackgroundColor.withAlphaComponent(selected ? 0.95 : 0.82)
            fill.setFill()
            path.fill()

            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 2 : 1
            path.stroke()

            let nameRect = rect.insetBy(dx: 10, dy: 9)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let name = NSAttributedString(
                string: item.name,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            name.draw(in: CGRect(
                x: nameRect.minX,
                y: nameRect.minY,
                width: nameRect.width,
                height: 16
            ))

            let detail = "\(Int(item.size.width))×\(Int(item.size.height))\(item.isMain ? " · MAIN" : "")"
            let detailString = NSAttributedString(
                string: detail,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: item.isMain ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            detailString.draw(in: CGRect(
                x: nameRect.minX,
                y: nameRect.minY + 18,
                width: nameRect.width,
                height: 13
            ))
        }

        let hint = "Positions are saved to the current preset only when you capture one."
        hint.draw(
            at: NSPoint(x: 24, y: bounds.height - 30),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectedIndex = nil
        dragIndex = nil
        guides = []
        for (index, item) in items.enumerated().reversed() where canvasRect(for: item).contains(point) {
            selectedIndex = index
            dragIndex = index
            dragOffset = CGPoint(
                x: point.x - canvasRect(for: item).minX,
                y: point.y - canvasRect(for: item).minY
            )
            appliedOrigin = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.origin) })
            if event.clickCount == 2 {
                let item = items[index]
                dragIndex = nil
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.model.runtime.arrangement.setMain(item.id)
                    self.model.refreshAll(seedHardware: false)
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.reload()
                }
            }
            needsDisplay = true
            return
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragIndex, items.indices.contains(index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let raw = displayPoint(from: CGPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y))
        let snapped = snap(origin: raw, size: items[index].size, excluding: index)
        items[index].origin = CGPoint(
            x: snapped.origin.x.rounded(),
            y: snapped.origin.y.rounded()
        )
        guides = snapped.guides
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragIndex = nil
        guides = []
        applyPositions()
    }

    private func snap(
        origin: CGPoint,
        size: CGSize,
        excluding index: Int
    ) -> (origin: CGPoint, guides: [ArrangementGuide]) {
        let tolerance = 10 / max(scale, 0.1)
        var x = origin.x
        var y = origin.y
        var guides: [ArrangementGuide] = []

        var bestX: (delta: CGFloat, value: CGFloat, guide: CGFloat)?
        var bestY: (delta: CGFloat, value: CGFloat, guide: CGFloat)?

        for (otherIndex, item) in items.enumerated() where otherIndex != index {
            let other = CGRect(origin: item.origin, size: item.size)
            let xCandidates: [(CGFloat, CGFloat)] = [
                (other.minX, other.minX),                       // left to left
                (other.maxX, other.minX),                       // left to right
                (other.minX - size.width, other.minX),          // right to left
                (other.maxX - size.width, other.maxX),          // right to right
                (other.midX - size.width / 2, other.midX),      // centers
            ]
            for (candidate, guide) in xCandidates {
                let delta = abs(candidate - origin.x)
                if delta < tolerance, bestX == nil || delta < bestX!.delta {
                    bestX = (delta, candidate, guide)
                }
            }

            let yCandidates: [(CGFloat, CGFloat)] = [
                (other.minY, other.minY),
                (other.maxY, other.minY),
                (other.minY - size.height, other.minY),
                (other.maxY - size.height, other.maxY),
                (other.midY - size.height / 2, other.midY),
            ]
            for (candidate, guide) in yCandidates {
                let delta = abs(candidate - origin.y)
                if delta < tolerance, bestY == nil || delta < bestY!.delta {
                    bestY = (delta, candidate, guide)
                }
            }
        }

        if let bestX {
            x = bestX.value
            let canvasX = layoutOrigin.x + bestX.guide * scale
            guides.append(ArrangementGuide(vertical: true, position: canvasX))
        }
        if let bestY {
            y = bestY.value
            let canvasY = layoutOrigin.y + bestY.guide * scale
            guides.append(ArrangementGuide(vertical: false, position: canvasY))
        }
        return (CGPoint(x: x, y: y), guides)
    }

    private func applyPositions() {
        var positions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.origin) })

        // macOS keeps the main display at (0, 0). If the user dragged the main display,
        // translate everything so the layout stays relative but the main returns to origin.
        if let main = items.first(where: \.isMain),
           let mainOrigin = positions[main.id],
           mainOrigin != .zero {
            positions = positions.mapValues {
                CGPoint(x: $0.x - mainOrigin.x, y: $0.y - mainOrigin.y)
            }
        }

        let target = positions
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.model.applyArrangement(target)
            if !ok {
                self.model.showError("Could not apply the display arrangement")
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.reload()
        }
    }
}

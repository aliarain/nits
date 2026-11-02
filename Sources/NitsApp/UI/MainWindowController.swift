import AppKit
import Combine
import NitsCore

/// The docked, sidebar-style window: displays and tools on the left, the selected
/// display's full controls on the right. It reuses the menu panel's cards and the settings
/// pages, so both front ends drive the same model.
@MainActor
final class MainWindowController {
    private let model: AppModel
    private var window: NSWindow?
    private var split: MainSplitViewController?

    init(model: AppModel) {
        self.model = model
    }

    func snapshotView() -> NSView? {
        window?.contentView?.superview ?? window?.contentView
    }

    func show() {
        if window == nil {
            let split = MainSplitViewController(model: model)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Nits"
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 760, height: 520)
            window.contentViewController = split
            window.setFrameAutosaveName("NitsMainWindow")
            if !window.setFrameUsingName("NitsMainWindow") { window.center() }
            self.split = split
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Split

enum SidebarSelection: Equatable {
    case display(String)
    case settings
}

@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let model: AppModel
    private let sidebar: SidebarViewController
    private var detailItem: NSSplitViewItem?
    private var currentDetail: NSViewController?

    init(model: AppModel) {
        self.model = model
        self.sidebar = SidebarViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 280
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let placeholder = NSViewController()
        placeholder.view = NSView()
        let item = NSSplitViewItem(viewController: placeholder)
        item.minimumThickness = 460
        addSplitViewItem(item)
        detailItem = item
        currentDetail = placeholder

        sidebar.onSelect = { [weak self] selection in self?.show(selection) }
        sidebar.start()
    }

    private func show(_ selection: SidebarSelection) {
        let next: NSViewController
        switch selection {
        case .display(let id):
            next = DisplayDetailViewController(model: model, rowID: id)
        case .settings:
            next = SettingsViewController(model: model)
        }
        guard let detailItem else { return }
        removeSplitViewItem(detailItem)
        let replacement = NSSplitViewItem(viewController: next)
        replacement.minimumThickness = 460
        addSplitViewItem(replacement)
        self.detailItem = replacement
        currentDetail = next
    }
}

// MARK: - Sidebar

@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Entry {
        case header(String)
        case display(DisplayRowState)
        case disconnected(DisconnectedDisplay)
        case settings
    }

    var onSelect: ((SidebarSelection) -> Void)?

    private let model: AppModel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var entries: [Entry] = []
    private var selection: SidebarSelection?
    private var cancellables = Set<AnyCancellable>()
    private var suppressSelectionCallback = false

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        view = effect

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.floatsGroupRows = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = buildFooter()
        effect.addSubview(scroll)
        effect.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 38),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func buildFooter() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let arrange = Theme.iconButton("rectangle.3.group", target: self, action: #selector(arrangePressed), tooltip: "Arrange displays")
        let refresh = Theme.iconButton("arrow.clockwise", target: self, action: #selector(refreshPressed), tooltip: "Refresh")
        let row = Theme.horizontal([arrange, refresh, Theme.flexibleSpace()], spacing: 10)
        container.addSubview(row)
        Theme.pin(row, to: container, insets: NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
        return container
    }

    func start() {
        model.$rows
            .combineLatest(model.$disconnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] rows, disconnected in self?.rebuild(rows: rows, disconnected: disconnected) }
            .store(in: &cancellables)
    }

    private func rebuild(rows: [DisplayRowState], disconnected: [DisconnectedDisplay]) {
        var next: [Entry] = [.header("Displays")]
        next += rows.map(Entry.display)
        if !disconnected.isEmpty {
            next.append(.header("Disconnected"))
            next += disconnected.map(Entry.disconnected)
        }
        next.append(.header("Nits"))
        next.append(.settings)

        let previous = entries
        entries = next

        // Keep the selection valid: stay put when possible, otherwise fall to the first display.
        var wanted = selection
        if case .display(let id)? = wanted, !rows.contains(where: { $0.id == id }) { wanted = nil }
        if wanted == nil, ProcessInfo.processInfo.environment["NITS_MAIN_SELECT"] == "settings" {
            wanted = .settings
        }
        if wanted == nil, let first = rows.first { wanted = .display(first.id) }

        let sameShape = previous.count == next.count && zip(previous, next).allSatisfy { Self.sameRow($0, $1) }
        suppressSelectionCallback = true
        if sameShape {
            // Refresh the visible cells in place so a slider drag is never interrupted.
            for index in entries.indices { refreshCell(at: index) }
        } else {
            table.reloadData()
        }
        if let wanted, let index = index(of: wanted) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        suppressSelectionCallback = false

        if wanted != selection, let wanted {
            selection = wanted
            onSelect?(wanted)
        }
    }

    private static func sameRow(_ a: Entry, _ b: Entry) -> Bool {
        switch (a, b) {
        case (.header(let x), .header(let y)): return x == y
        case (.display(let x), .display(let y)): return x.id == y.id
        case (.disconnected(let x), .disconnected(let y)): return x.uuid == y.uuid
        case (.settings, .settings): return true
        default: return false
        }
    }

    private func index(of selection: SidebarSelection) -> Int? {
        entries.firstIndex {
            switch ($0, selection) {
            case (.display(let row), .display(let id)): return row.id == id
            case (.settings, .settings): return true
            default: return false
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = entries[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch entries[row] {
        case .display, .settings: return true
        case .header, .disconnected: return false
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch entries[row] {
        case .header: return 26
        case .display: return 46
        case .disconnected, .settings: return 34
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarCell()
        configure(cell, for: entries[row])
        return cell
    }

    private func refreshCell(at index: Int) {
        guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCell else { return }
        configure(cell, for: entries[index])
    }

    private func configure(_ cell: SidebarCell, for entry: Entry) {
        switch entry {
        case .header(let title):
            cell.set(title: title.uppercased(), subtitle: nil, symbol: nil, header: true)
        case .display(let row):
            let mode = row.state.currentMode
            var parts: [String] = []
            if let mode { parts.append("\(mode.width)×\(mode.height)\(mode.isHiDPI ? " HiDPI" : "")") }
            if let hz = mode?.refreshRate, hz > 0 { parts.append(String(format: "%.0f Hz", hz)) }
            cell.set(
                title: row.display.name,
                subtitle: parts.joined(separator: " · "),
                symbol: row.display.isBuiltin ? "laptopcomputer" : "display",
                header: false
            )
        case .disconnected(let record):
            cell.set(title: record.name, subtitle: nil, symbol: "display.slash", header: false, dim: true)
        case .settings:
            cell.set(title: "Settings", subtitle: nil, symbol: "gearshape", header: false)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        let next: SidebarSelection
        switch entries[row] {
        case .display(let state): next = .display(state.id)
        case .settings: next = .settings
        default: return
        }
        guard next != selection else { return }
        selection = next
        onSelect?(next)
    }

    @objc private func arrangePressed() {
        let controller = ArrangementWindowController(model: model)
        arrangement = controller
        controller.show(relativeTo: view.window)
    }

    private var arrangement: ArrangementWindowController?

    @objc private func refreshPressed() {
        model.refreshAll(seedHardware: true)
    }
}

@MainActor
private final class SidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = Theme.label("", size: 12, weight: .medium)
    private let subtitle = Theme.label("", size: 10, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        let text = Theme.vertical([title, subtitle], spacing: 1)
        let row = Theme.horizontal([icon, text], spacing: 9)
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(title: String, subtitle: String?, symbol: String?, header: Bool, dim: Bool = false) {
        self.title.stringValue = title
        self.title.font = header ? .systemFont(ofSize: 10, weight: .semibold) : .systemFont(ofSize: 12, weight: .medium)
        self.title.textColor = header ? .tertiaryLabelColor : (dim ? .secondaryLabelColor : .labelColor)
        self.subtitle.stringValue = subtitle ?? ""
        self.subtitle.isHidden = (subtitle ?? "").isEmpty
        icon.isHidden = symbol == nil
        icon.image = symbol.flatMap { Theme.symbol($0, size: 15) }
    }
}

// MARK: - Detail

@MainActor
final class DisplayDetailViewController: NSViewController {
    private let model: AppModel
    private let rowID: String
    private let scroll = NSScrollView()
    private let content = NSStackView()
    private let iconView = NSImageView()
    private let nameLabel = Theme.label("", size: 22, weight: .bold)
    private let subtitleLabel = Theme.label("", size: 12, color: .secondaryLabelColor)
    private let presetsBar = PresetsBarView()
    private var card: DisplayCardView?
    private var cancellables = Set<AnyCancellable>()
    private var modePicker: ModePickerWindowController?
    private var savePreset: SavePresetWindowController?

    init(model: AppModel, rowID: String) {
        self.model = model
        self.rowID = rowID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let document = TopAlignedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)

        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let titles = Theme.vertical([nameLabel, subtitleLabel], spacing: 2)
        let header = Theme.horizontal([iconView, titles, Theme.flexibleSpace()], spacing: 12)
        content.addArrangedSubview(header)

        presetsBar.onApply = { [weak self] id in self?.model.applyPreset(id: id) }
        presetsBar.onDelete = { [weak self] id in self?.model.deletePreset(id: id) }
        presetsBar.onSave = { [weak self] in self?.presentSavePreset() }
        presetsBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        content.addArrangedSubview(presetsBar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -28),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            presetsBar.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        let fill = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -56)
        fill.priority = .defaultHigh
        fill.isActive = true

        model.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] rows in self?.render(rows) }
            .store(in: &cancellables)
        model.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] presets in self?.presetsBar.setPresets(presets) }
            .store(in: &cancellables)
    }

    private func render(_ rows: [DisplayRowState]) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        nameLabel.stringValue = row.display.name
        iconView.image = Theme.symbol(row.display.isBuiltin ? "laptopcomputer" : "display", size: 34, weight: .light)
        let mode = row.state.currentMode
        var parts: [String] = [row.display.isBuiltin ? "Built-in" : row.display.connection]
        if let mode { parts.append("\(mode.width)×\(mode.height)\(mode.isHiDPI ? " HiDPI" : "")") }
        if let hz = mode?.refreshRate, hz > 0 { parts.append(String(format: "%.0f Hz", hz)) }
        subtitleLabel.stringValue = parts.joined(separator: " · ")

        if let card {
            card.update(row)
        } else {
            let card = DisplayCardView(
                model: model,
                row: row,
                forceExpanded: true,
                onPickMode: { [weak self] id in
                    guard let self else { return }
                    let controller = ModePickerWindowController(model: self.model, rowID: id)
                    self.modePicker = controller
                    controller.show(relativeTo: self.view.window)
                }
            )
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            self.card = card
        }
    }

    private func presentSavePreset() {
        let controller = SavePresetWindowController(model: model)
        savePreset = controller
        controller.show(relativeTo: view.window)
    }
}

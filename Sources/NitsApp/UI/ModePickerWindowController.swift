import AppKit
import NitsCore

@MainActor
final class ModePickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let rowID: String
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let applyButton = NSButton()
    private let subtitle = Theme.label("", size: 10, color: .secondaryLabelColor)

    private var allModes: [DisplayModeInfo] = []
    private var filtered: [DisplayModeInfo] = []
    private var currentModeID: Int32?

    init(model: AppModel, rowID: String) {
        self.model = model
        self.rowID = rowID

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Resolution"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo parent: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let title = Theme.label("Choose a resolution", size: 14, weight: .semibold)

        searchField.placeholderString = "Search resolutions"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(applySelection)
        tableView.allowsEmptySelection = true
        tableView.style = .inset

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        applyButton.title = "Apply"
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applySelection)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let headerStack = Theme.vertical([title, subtitle], spacing: 2)
        let buttonRow = Theme.horizontal([Theme.flexibleSpace(), cancel, applyButton], spacing: 8)

        content.addSubview(headerStack)
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func reload() {
        guard let row = model.rows.first(where: { $0.id == rowID }) else { return }
        allModes = row.state.modes
        currentModeID = row.state.currentMode?.id
        let search = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        filtered = search.isEmpty
            ? allModes
            : allModes.filter { $0.label.localizedCaseInsensitiveContains(search) }
        tableView.reloadData()
        if let current = currentModeID,
           let index = filtered.firstIndex(where: { $0.id == current }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        applyButton.isEnabled = tableView.selectedRow >= 0
        subtitle.stringValue = "\(allModes.count) modes · now \(row.state.currentMode?.label ?? "unknown")"
    }

    @objc private func searchChanged() {
        reload()
    }

    @objc private func applySelection() {
        let index = tableView.selectedRow
        guard index >= 0, index < filtered.count else { return }
        let mode = filtered[index]
        model.setMode(mode, rowID: rowID)
        window?.close()
    }

    @objc private func cancelPressed() {
        window?.close()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("modeCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let mode = filtered[row]
        let current = mode.id == currentModeID ? "✓  " : "     "
        let hidpi = mode.isHiDPI ? "HiDPI" : "     "
        let refresh = mode.refreshRate > 0 ? String(format: "%.2f Hz", mode.refreshRate) : "default"
        cell.textField?.stringValue = "\(current)\(mode.width) × \(mode.height)    \(hidpi)    \(refresh)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        applyButton.isEnabled = tableView.selectedRow >= 0
    }
}

import AppKit
import Combine
import NitsCore

@MainActor
final class MenuPanelViewController: NSViewController {
    private let model: AppModel
    private let openSettings: () -> Void
    private let quit: () -> Void

    private let scroll = NSScrollView()
    private let contentStack = NSStackView()
    private let cardsStack = NSStackView()
    private let disconnectedStack = NSStackView()
    private let presetsBar = PresetsBarView()
    private let bannerContainer = NSStackView()
    private let bannerLabel = Theme.label("", size: 10, lines: 2)
    private let emptyLabel = Theme.label(
        "No displays found.\nConnect a display, then refresh.",
        size: 11,
        color: .secondaryLabelColor,
        lines: 2
    )
    private let refreshSpinner = NSProgressIndicator()
    private let headerRefresh = NSButton()
    private let moonButton = NSButton()
    private let eyeButton = NSButton()

    private var cardViews: [String: DisplayCardView] = [:]
    private var renderedRowIDs: [String] = []
    private var cancellables = Set<AnyCancellable>()
    private var modePicker: ModePickerWindowController?
    private var savePresetController: SavePresetWindowController?
    private var arrangementController: ArrangementWindowController?

    init(model: AppModel, openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
        self.quit = quit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 620))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        preferredContentSize = NSSize(width: Theme.panelWidth, height: 420)
        build()
        observe()
        if ProcessInfo.processInfo.environment["NITS_SHOW_ARRANGEMENT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.arrangePressed()
                if let path = ProcessInfo.processInfo.environment["NITS_ARRANGEMENT_SNAPSHOT_PATH"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let view = self?.arrangementController?.window?.contentView,
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
    }

    // MARK: - Layout

    private func build() {
        let header = buildHeader()
        view.addSubview(header)
        view.addSubview(presetsBar)

        buildScroll()
        view.addSubview(scroll)

        buildBanner()
        view.addSubview(bannerContainer)

        let footer = buildFooter()
        view.addSubview(footer)
        let divider = Theme.divider()
        view.addSubview(divider)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 46),

            presetsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            presetsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            presetsBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            presetsBar.heightAnchor.constraint(equalToConstant: 40),

            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: presetsBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bannerContainer.topAnchor),

            bannerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bannerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerContainer.bottomAnchor.constraint(equalTo: divider.topAnchor),

            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 38),
        ])

        presetsBar.onApply = { [weak self] id in self?.model.applyPreset(id: id) }
        presetsBar.onDelete = { [weak self] id in self?.model.deletePreset(id: id) }
        presetsBar.onSave = { [weak self] in self?.presentSavePreset() }
    }

    private func buildHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = Theme.label("Nits", size: 15, weight: .semibold)
        let subtitle = Theme.label("Display control", size: 10, color: .secondaryLabelColor)
        let titles = Theme.vertical([title, subtitle], spacing: 0)

        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isDisplayedWhenStopped = false
        refreshSpinner.translatesAutoresizingMaskIntoConstraints = false
        refreshSpinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        refreshSpinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        headerRefresh.image = Theme.symbol("arrow.clockwise", size: 12)
        headerRefresh.isBordered = false
        headerRefresh.imagePosition = .imageOnly
        headerRefresh.target = self
        headerRefresh.action = #selector(refreshPressed)
        headerRefresh.toolTip = "Refresh displays"
        headerRefresh.translatesAutoresizingMaskIntoConstraints = false

        let arrange = Theme.iconButton(
            "rectangle.3.group",
            target: self,
            action: #selector(arrangePressed),
            tooltip: "Arrange displays"
        )
        let row = Theme.horizontal([titles, Theme.flexibleSpace(), arrange, refreshSpinner, headerRefresh], spacing: 6)
        container.addSubview(row)
        Theme.pin(row, to: container, insets: NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14))
        return container
    }

    private func buildScroll() {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = TopAlignedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 10
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        disconnectedStack.orientation = .vertical
        disconnectedStack.alignment = .leading
        disconnectedStack.spacing = 6
        disconnectedStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(emptyLabel)
        contentStack.addArrangedSubview(cardsStack)
        contentStack.addArrangedSubview(disconnectedStack)

        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            cardsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            disconnectedStack.widthAnchor.constraint(equalTo: cardsStack.widthAnchor),
            emptyLabel.widthAnchor.constraint(equalTo: cardsStack.widthAnchor),
        ])
    }

    private func buildBanner() {
        bannerContainer.orientation = .vertical
        bannerContainer.alignment = .leading
        bannerContainer.spacing = 0
        bannerContainer.edgeInsets = NSEdgeInsets()
        bannerContainer.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addArrangedSubview(bannerLabel)
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.isHidden = true
        bannerLabel.widthAnchor.constraint(equalTo: bannerContainer.widthAnchor, constant: -28).isActive = true
    }

    private func buildFooter() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        moonButton.image = Theme.symbol("moon.fill", size: 12)
        moonButton.isBordered = false
        moonButton.imagePosition = .imageOnly
        moonButton.target = self
        moonButton.action = #selector(toggleDarkMode)
        moonButton.toolTip = "Dark Mode"
        moonButton.translatesAutoresizingMaskIntoConstraints = false
        moonButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        eyeButton.image = Theme.symbol("eye.fill", size: 12)
        eyeButton.isBordered = false
        eyeButton.imagePosition = .imageOnly
        eyeButton.target = self
        eyeButton.action = #selector(toggleKeepAwake)
        eyeButton.toolTip = "Keep displays awake"
        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let gear = Theme.iconButton("gearshape", target: self, action: #selector(settingsPressed), tooltip: "Settings")
        let power = Theme.iconButton("power", target: self, action: #selector(quitPressed), tooltip: "Quit Nits")

        let row = Theme.horizontal([moonButton, eyeButton, Theme.flexibleSpace(), gear, power], spacing: 10)
        container.addSubview(row)
        Theme.pin(row, to: container, insets: NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14))
        return container
    }

    // MARK: - Model observation

    private func observe() {
        model.$rows
            .receive(on: RunLoop.main)
            .sink { [weak self] rows in self?.render(rows: rows) }
            .store(in: &cancellables)

        model.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] presets in self?.presetsBar.setPresets(presets) }
            .store(in: &cancellables)

        model.$disconnected
            .receive(on: RunLoop.main)
            .sink { [weak self] records in self?.renderDisconnected(records) }
            .store(in: &cancellables)

        model.$isRefreshing
            .receive(on: RunLoop.main)
            .sink { [weak self] refreshing in
                guard let self else { return }
                if refreshing { self.refreshSpinner.startAnimation(nil) }
                else { self.refreshSpinner.stopAnimation(nil) }
            }
            .store(in: &cancellables)

        model.$keepAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                self?.eyeButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            }
            .store(in: &cancellables)

        model.$isDarkMode
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                self?.moonButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
            }
            .store(in: &cancellables)

        model.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderBanner() }
            .store(in: &cancellables)

        model.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderBanner() }
            .store(in: &cancellables)
    }

    private func render(rows: [DisplayRowState]) {
        emptyLabel.isHidden = !rows.isEmpty
        let ids = rows.map(\.id)
        if ids != renderedRowIDs {
            renderedRowIDs = ids
            rebuildCards(rows)
        } else {
            for row in rows {
                cardViews[row.id]?.update(row)
            }
        }
        updatePreferredHeight()
    }

    private func rebuildCards(_ rows: [DisplayRowState]) {
        for view in cardsStack.arrangedSubviews {
            cardsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardViews.removeAll()

        for row in rows {
            let card = DisplayCardView(
                model: model,
                row: row,
                onPickMode: { [weak self] rowID in
                    guard let self else { return }
                    let controller = ModePickerWindowController(model: self.model, rowID: rowID)
                    self.modePicker = controller
                    controller.show(relativeTo: self.view.window)
                }
            )
            cardsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: cardsStack.widthAnchor).isActive = true
            cardViews[row.id] = card
        }
    }

    private func renderDisconnected(_ records: [DisconnectedDisplay]) {
        for view in disconnectedStack.arrangedSubviews {
            disconnectedStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !records.isEmpty else { return }

        disconnectedStack.addArrangedSubview(Theme.label("DISCONNECTED", size: 9, weight: .semibold, color: .tertiaryLabelColor))
        for (index, record) in records.enumerated() {
            let icon = NSImageView()
            icon.image = Theme.symbol("display.slash", size: 11)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

            let name = Theme.label(record.name, size: 11)
            let reconnect = NSButton(title: "Reconnect", target: self, action: #selector(reconnectPressed(_:)))
            reconnect.bezelStyle = .rounded
            reconnect.controlSize = .small
            reconnect.font = .systemFont(ofSize: 10)
            reconnect.tag = index

            let row = Theme.horizontal([icon, name, Theme.flexibleSpace(), reconnect], spacing: 8)
            let background = CardView()
            background.addSubview(row)
            Theme.pin(row, to: background, insets: NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9))
            disconnectedStack.addArrangedSubview(background)
            background.widthAnchor.constraint(equalTo: disconnectedStack.widthAnchor).isActive = true
        }
        updatePreferredHeight()
    }

    private func updatePreferredHeight() {
        let chrome: CGFloat = 46 + 40 + 38 + 2
        let banner = bannerLabel.isHidden ? 0 : bannerContainer.fittingSize.height
        let content = contentStack.fittingSize.height
        let height = min(680, max(260, chrome + content + banner))
        if abs(preferredContentSize.height - height) > 1 {
            preferredContentSize = NSSize(width: Theme.panelWidth, height: height)
        }
    }

    private func renderBanner() {
        let message = model.errorMessage ?? model.statusMessage
        guard let message else {
            bannerLabel.isHidden = true
            bannerContainer.edgeInsets = NSEdgeInsets()
            return
        }
        bannerLabel.isHidden = false
        bannerLabel.stringValue = message
        bannerLabel.textColor = model.errorMessage != nil ? .systemOrange : .secondaryLabelColor
        bannerContainer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        updatePreferredHeight()
    }

    // MARK: - Actions

    @objc private func refreshPressed() {
        model.refreshAll(seedHardware: true)
    }

    @objc private func arrangePressed() {
        let controller = ArrangementWindowController(model: model)
        arrangementController = controller
        controller.show(relativeTo: view.window)
    }

    @objc private func toggleDarkMode() {
        model.toggleDarkMode()
    }

    @objc private func toggleKeepAwake() {
        model.setKeepAwake(!model.keepAwake)
    }

    @objc private func settingsPressed() {
        openSettings()
    }

    @objc private func quitPressed() {
        quit()
    }

    @objc private func reconnectPressed(_ sender: NSButton) {
        let records = model.disconnected
        guard sender.tag >= 0, sender.tag < records.count else { return }
        model.reconnect(records[sender.tag])
    }

    private func presentSavePreset() {
        let controller = SavePresetWindowController(model: model)
        savePresetController = controller
        controller.show(relativeTo: view.window)
    }
}

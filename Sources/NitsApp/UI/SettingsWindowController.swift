import AppKit
import Combine
import NitsCore

@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func snapshotView() -> NSView? {
        // The content view is transparent; the theme frame draws the window background.
        window?.contentView?.superview ?? window?.contentView
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nits Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = SettingsViewController(model: model)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsViewController: NSViewController {
    private let model: AppModel
    private let tabs = NSTabView()
    private let tabSelector = NSSegmentedControl(
        labels: ["General", "Shortcuts", "Groups", "Virtual", "Advanced", "About"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var cancellables = Set<AnyCancellable>()

    private let globalHotkeyStack = NSStackView()
    private let presetHotkeyStack = NSStackView()
    private let groupListStack = NSStackView()
    private let groupMemberStack = NSStackView()
    private let groupNameField = NSTextField()
    private var groupMemberCheckboxes: [String: NSButton] = [:]
    private let groupBrightness = NSButton(checkboxWithTitle: "Brightness", target: nil, action: nil)
    private let groupVolume = NSButton(checkboxWithTitle: "Volume", target: nil, action: nil)
    private let groupImage = NSButton(checkboxWithTitle: "Image adjustment", target: nil, action: nil)
    private let groupInput = NSButton(checkboxWithTitle: "Input", target: nil, action: nil)
    private let groupResolution = NSButton(checkboxWithTitle: "Resolution", target: nil, action: nil)
    private let groupSaveButton = NSButton()
    private var editingGroupID: UUID?
    private let virtualListStack = NSStackView()
    private let virtualNameField = NSTextField()
    private let virtualWidthField = NSTextField()
    private let virtualHeightField = NSTextField()
    private let virtualRefreshField = NSTextField()
    private let virtualHiDPIToggle = NSButton(
        checkboxWithTitle: "HiDPI", target: nil, action: nil
    )
    private let virtualAutoToggle = NSButton(
        checkboxWithTitle: "Create at launch", target: nil, action: nil
    )
    private let accessibilityLabel = Theme.label("", size: 10, color: .secondaryLabelColor)
    private let brightnessStepLabel = Theme.label("", size: 10)
    private let volumeStepLabel = Theme.label("", size: 10)
    private var checkboxes: [Int: NSButton] = [:]
    private var doctorController: DoctorWindowController?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 580))
        view = root
        build()
        observe()
    }

    // MARK: - Build

    private func build() {
        tabs.tabViewType = .noTabsNoBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabSelector.target = self
        tabSelector.action = #selector(tabChanged)
        tabSelector.selectedSegment = 0
        tabSelector.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tabSelector)
        view.addSubview(tabs)

        addTab("General", view: scrollable(generalContent()))
        addTab("Shortcuts", view: scrollable(shortcutsContent()))
        addTab("Groups", view: scrollable(groupsContent()))
        addTab("Virtual", view: scrollable(virtualContent()))
        addTab("Advanced", view: scrollable(advancedContent()))
        addTab("About", view: aboutContent())

        NSLayoutConstraint.activate([
            tabSelector.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabSelector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tabSelector.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            tabSelector.heightAnchor.constraint(equalToConstant: 24),

            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tabs.topAnchor.constraint(equalTo: tabSelector.bottomAnchor, constant: 8),
            tabs.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        rebuildShortcuts()
        syncControls()
        if let raw = ProcessInfo.processInfo.environment["NITS_SETTINGS_TAB"],
           let index = Int(raw),
           index >= 0,
           index < tabs.numberOfTabViewItems {
            tabSelector.selectedSegment = index
            tabs.selectTabViewItem(at: index)
        }
    }

    @objc private func tabChanged() {
        tabs.selectTabViewItem(at: tabSelector.selectedSegment)
    }

    private func addTab(_ title: String, view: NSView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        tabs.addTabViewItem(item)
    }

    private func scrollable(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.widthAnchor.constraint(equalTo: document.widthAnchor),
        ])
        return scroll
    }

    private func section(_ title: String) -> NSView {
        Theme.label(title.uppercased(), size: 9, weight: .semibold, color: .tertiaryLabelColor)
    }

    private func checkbox(_ title: String, tag: Int, on: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(generalToggle(_:)))
        button.tag = tag
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 11)
        checkboxes[tag] = button
        return button
    }

    private func generalContent() -> NSView {
        let settings = model.settings
        let stack = Theme.vertical([], spacing: 12, alignment: .leading)

        stack.addArrangedSubview(section("Interface"))
        stack.addArrangedSubview(checkbox(
            "Show on-screen display for keys and shortcuts",
            tag: 1,
            on: settings.showOSD
        ))
        stack.addArrangedSubview(checkbox(
            "Restore last brightness when a display connects",
            tag: 2,
            on: settings.restoreBrightnessOnConnect
        ))
        stack.addArrangedSubview(checkbox(
            "Synchronize brightness across displays",
            tag: 3,
            on: settings.syncBrightness
        ))

        stack.addArrangedSubview(section("Screen effects"))
        let nightShift = checkbox("Night Shift", tag: 7, on: model.nightShiftOn)
        nightShift.isEnabled = model.nightShiftAvailable
        if !model.nightShiftAvailable { nightShift.title = "Night Shift (unsupported)" }
        stack.addArrangedSubview(nightShift)
        let trueTone = checkbox("True Tone", tag: 8, on: model.trueToneOn)
        trueTone.isEnabled = model.trueToneAvailable
        if !model.trueToneAvailable { trueTone.title = "True Tone (unsupported)" }
        stack.addArrangedSubview(trueTone)

        stack.addArrangedSubview(section("Steps"))

        let brightnessStepper = NSStepper()
        brightnessStepper.minValue = 1
        brightnessStepper.maxValue = 25
        brightnessStepper.increment = 1
        brightnessStepper.doubleValue = settings.brightnessStep
        brightnessStepper.target = self
        brightnessStepper.action = #selector(brightnessStepChanged(_:))
        brightnessStepLabel.stringValue = "\(Int(settings.brightnessStep))%"
        let brightnessRow = Theme.horizontal(
            [Theme.label("Brightness step", size: 11), Theme.flexibleSpace(), brightnessStepLabel, brightnessStepper],
            spacing: 8
        )

        let volumeStepper = NSStepper()
        volumeStepper.minValue = 1
        volumeStepper.maxValue = 25
        volumeStepper.increment = 1
        volumeStepper.doubleValue = settings.volumeStep
        volumeStepper.target = self
        volumeStepper.action = #selector(volumeStepChanged(_:))
        volumeStepLabel.stringValue = "\(Int(settings.volumeStep))%"
        let volumeRow = Theme.horizontal(
            [Theme.label("Volume step", size: 11), Theme.flexibleSpace(), volumeStepLabel, volumeStepper],
            spacing: 8
        )

        stack.addArrangedSubview(brightnessRow)
        stack.addArrangedSubview(volumeRow)

        stack.addArrangedSubview(section("System"))
        stack.addArrangedSubview(checkbox("Launch at login", tag: 4, on: model.launchAtLogin))
        stack.addArrangedSubview(checkbox("Keep displays awake", tag: 5, on: model.keepAwake))
        stack.addArrangedSubview(checkbox(
            "Use brightness and volume keys",
            tag: 6,
            on: settings.mediaKeysEnabled
        ))

        accessibilityLabel.stringValue = model.accessibilityTrusted
            ? "Accessibility permission granted."
            : "Accessibility permission is required for the hardware media keys."
        let grant = NSButton(title: "Grant…", target: self, action: #selector(grantAccessibility))
        grant.bezelStyle = .rounded
        grant.controlSize = .small
        let accessibilityRow = Theme.horizontal(
            [accessibilityLabel, Theme.flexibleSpace(), grant],
            spacing: 8
        )
        stack.addArrangedSubview(accessibilityRow)

        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        return stack
    }

    private func shortcutsContent() -> NSView {
        globalHotkeyStack.orientation = .vertical
        globalHotkeyStack.alignment = .leading
        globalHotkeyStack.spacing = 8
        globalHotkeyStack.translatesAutoresizingMaskIntoConstraints = false

        presetHotkeyStack.orientation = .vertical
        presetHotkeyStack.alignment = .leading
        presetHotkeyStack.spacing = 8
        presetHotkeyStack.translatesAutoresizingMaskIntoConstraints = false

        let note = Theme.label(
            "Shortcuts are system-wide and need no Accessibility permission. Press Escape while recording to clear.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 2
        )

        let stack = Theme.vertical(
            [section("Global shortcuts"), globalHotkeyStack, section("Presets"), presetHotkeyStack, note],
            spacing: 10,
            alignment: .leading
        )
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func advancedContent() -> NSView {
        let stack = Theme.vertical([], spacing: 12, alignment: .leading)
        stack.addArrangedSubview(section("Diagnostics"))
        stack.addArrangedSubview(Theme.label(
            "Full report: identities, DDC channel pairing, VCP probes, raw replies, private API availability and recent log.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 3
        ))

        let configPath = Theme.label(model.runtime.config.url.path, size: 9, color: .secondaryLabelColor, lines: 2)
        configPath.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        stack.addArrangedSubview(configPath)

        let run = NSButton(title: "Run diagnostics", target: self, action: #selector(runDoctor))
        run.bezelStyle = .rounded
        let openFolder = NSButton(title: "Open config folder", target: self, action: #selector(openConfigFolder))
        openFolder.bezelStyle = .rounded
        let reveal = NSButton(title: "Reveal config file", target: self, action: #selector(revealConfig))
        reveal.bezelStyle = .rounded
        stack.addArrangedSubview(Theme.horizontal([run, openFolder, reveal, Theme.flexibleSpace()], spacing: 8))

        stack.addArrangedSubview(section("Recovery"))
        let resetImage = NSButton(title: "Reset all image adjustments", target: self, action: #selector(resetImageAdjustments))
        resetImage.bezelStyle = .rounded
        let refreshDDC = NSButton(title: "Refresh DDC channels", target: self, action: #selector(refreshDDC))
        refreshDDC.bezelStyle = .rounded
        stack.addArrangedSubview(Theme.horizontal([resetImage, refreshDDC, Theme.flexibleSpace()], spacing: 8))

        stack.addArrangedSubview(section("How Nits talks to hardware"))
        stack.addArrangedSubview(Theme.label(
            """
            Apple panels use DisplayServices. External monitors use DDC/CI over IOAVService (Apple Silicon) \
            or IOFramebuffer I2C (Intel). Every reply is validated by header and checksum, reads are quarantined \
            after repeated failures, and the channel map is flushed on reconfiguration. Private APIs (disconnect, \
            hidden modes, rotation) are optional and never required for launch.
            """,
            size: 10,
            color: .secondaryLabelColor,
            lines: 8
        ))

        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func groupsContent() -> NSView {
        for stack in [groupListStack, groupMemberStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        groupNameField.placeholderString = "Group name"
        for toggle in [groupBrightness, groupVolume, groupImage, groupInput, groupResolution] {
            toggle.font = .systemFont(ofSize: 10)
        }
        groupBrightness.state = .on

        groupSaveButton.title = "Create Group"
        groupSaveButton.bezelStyle = .rounded
        groupSaveButton.target = self
        groupSaveButton.action = #selector(saveGroupPressed)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelGroupEdit))
        cancel.bezelStyle = .rounded

        let nameRow = Theme.horizontal(
            [Theme.label("Name", size: 11), groupNameField, Theme.flexibleSpace()],
            spacing: 8
        )
        let syncRow = Theme.horizontal(
            [groupBrightness, groupVolume, groupImage, groupInput, groupResolution, Theme.flexibleSpace()],
            spacing: 10
        )
        let note = Theme.label(
            "Group members share the checked controls. Brightness is the everyday case; image sync mirrors gamma/contrast, input sync sends the same VCP 0x60, and resolution sync applies the same logical mode where possible.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 4
        )
        let buttons = Theme.horizontal([groupSaveButton, cancel, Theme.flexibleSpace()], spacing: 8)

        let stack = Theme.vertical(
            [
                section("Groups"), groupListStack,
                section("Create or edit"), nameRow,
                section("Displays"), groupMemberStack,
                section("Synchronize"), syncRow,
                buttons, note,
            ],
            spacing: 10,
            alignment: .leading
        )
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rebuildGroupList()
        rebuildGroupMembers()
        return stack
    }

    private func rebuildGroupList() {
        for view in groupListStack.arrangedSubviews {
            groupListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if model.groups.isEmpty {
            groupListStack.addArrangedSubview(
                Theme.label("No groups yet. Create one below.", size: 10, color: .secondaryLabelColor)
            )
            return
        }
        let names = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0.display.name) })
        for (index, group) in model.groups.enumerated() {
            let members = group.displayUUIDs.compactMap { names[$0] }.joined(separator: ", ")
            var flags: [String] = []
            if group.syncBrightness { flags.append("brightness") }
            if group.syncVolume { flags.append("volume") }
            if group.syncImage { flags.append("image") }
            if group.syncInput { flags.append("input") }
            if group.syncResolution { flags.append("resolution") }
            let edit = NSButton(title: "Edit", target: self, action: #selector(editGroupPressed(_:)))
            edit.bezelStyle = .rounded
            edit.controlSize = .small
            edit.font = .systemFont(ofSize: 9)
            edit.tag = index
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteGroupPressed(_:)))
            delete.bezelStyle = .rounded
            delete.controlSize = .small
            delete.font = .systemFont(ofSize: 9)
            delete.tag = index

            let row = Theme.horizontal(
                [
                    Theme.label(group.name, size: 11, weight: .medium),
                    Theme.label(members.isEmpty ? "no members" : members, size: 9, color: .secondaryLabelColor),
                    Theme.label(flags.joined(separator: " · "), size: 9, color: .tertiaryLabelColor),
                    Theme.flexibleSpace(),
                    edit, delete,
                ],
                spacing: 8
            )
            groupListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: groupListStack.widthAnchor).isActive = true
        }
    }

    private func rebuildGroupMembers(selecting selection: Set<String>? = nil) {
        let selected = selection ?? Set(
            groupMemberCheckboxes.compactMap { $0.value.state == .on ? $0.key : nil }
        )
        for view in groupMemberStack.arrangedSubviews {
            groupMemberStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        groupMemberCheckboxes.removeAll()

        for row in model.rows {
            let button = NSButton(
                checkboxWithTitle: row.display.name,
                target: nil,
                action: nil
            )
            button.font = .systemFont(ofSize: 10)
            button.state = selected.contains(row.id) ? .on : .off
            button.translatesAutoresizingMaskIntoConstraints = false
            groupMemberCheckboxes[row.id] = button
            groupMemberStack.addArrangedSubview(button)
        }
        if model.rows.isEmpty {
            groupMemberStack.addArrangedSubview(
                Theme.label("No displays connected.", size: 10, color: .secondaryLabelColor)
            )
        }
    }

    private func resetGroupForm() {
        editingGroupID = nil
        groupNameField.stringValue = ""
        groupSaveButton.title = "Create Group"
        for toggle in [groupBrightness, groupVolume, groupImage, groupInput, groupResolution] {
            toggle.state = .off
        }
        groupBrightness.state = .on
        rebuildGroupMembers(selecting: [])
    }

    @objc private func saveGroupPressed() {
        let name = groupNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        let members = groupMemberCheckboxes
            .filter { $0.value.state == .on }
            .map(\.key)
        guard !members.isEmpty else {
            NSSound.beep()
            return
        }
        let group = DisplayGroup(
            id: editingGroupID ?? UUID(),
            name: name,
            displayUUIDs: members,
            syncBrightness: groupBrightness.state == .on,
            syncVolume: groupVolume.state == .on,
            syncImage: groupImage.state == .on,
            syncInput: groupInput.state == .on,
            syncResolution: groupResolution.state == .on
        )
        model.saveGroup(group)
        resetGroupForm()
    }

    @objc private func editGroupPressed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < model.groups.count else { return }
        let group = model.groups[sender.tag]
        editingGroupID = group.id
        groupNameField.stringValue = group.name
        groupSaveButton.title = "Save Group"
        groupBrightness.state = group.syncBrightness ? .on : .off
        groupVolume.state = group.syncVolume ? .on : .off
        groupImage.state = group.syncImage ? .on : .off
        groupInput.state = group.syncInput ? .on : .off
        groupResolution.state = group.syncResolution ? .on : .off
        rebuildGroupMembers(selecting: Set(group.displayUUIDs))
    }

    @objc private func deleteGroupPressed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < model.groups.count else { return }
        model.deleteGroup(id: model.groups[sender.tag].id)
        if editingGroupID == model.groups[sender.tag].id {
            resetGroupForm()
        }
    }

    @objc private func cancelGroupEdit() {
        resetGroupForm()
    }

    private func virtualContent() -> NSView {
        virtualListStack.orientation = .vertical
        virtualListStack.alignment = .leading
        virtualListStack.spacing = 8
        virtualListStack.translatesAutoresizingMaskIntoConstraints = false

        virtualNameField.placeholderString = "Virtual Display"
        virtualWidthField.stringValue = "2560"
        virtualHeightField.stringValue = "1440"
        virtualRefreshField.stringValue = "60"
        for field in [virtualWidthField, virtualHeightField, virtualRefreshField] {
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        virtualHiDPIToggle.state = .on
        virtualAutoToggle.state = .on

        let create = NSButton(title: "Create Virtual Display", target: self, action: #selector(createVirtualPressed))
        create.bezelStyle = .rounded

        let nameRow = Theme.horizontal(
            [Theme.label("Name", size: 11), virtualNameField, Theme.flexibleSpace()],
            spacing: 8
        )
        let sizeRow = Theme.horizontal(
            [
                Theme.label("Size", size: 11),
                virtualWidthField,
                Theme.label("×", size: 11),
                virtualHeightField,
                Theme.label("Refresh", size: 11),
                virtualRefreshField,
                Theme.label("Hz", size: 11),
                Theme.flexibleSpace(),
            ],
            spacing: 6
        )
        let toggleRow = Theme.horizontal(
            [virtualHiDPIToggle, virtualAutoToggle, Theme.flexibleSpace()],
            spacing: 12
        )

        let note = Theme.label(
            "Virtual displays are owned by Nits and disappear when it quits. Auto-created ones return on launch. DDC does not apply; brightness uses software dimming.",
            size: 10,
            color: .secondaryLabelColor,
            lines: 3
        )

        let stack = Theme.vertical(
            [section("Configured"), virtualListStack, section("Create"), nameRow, sizeRow, toggleRow, create, note],
            spacing: 10,
            alignment: .leading
        )
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 20, right: 20)
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rebuildVirtualList()
        return stack
    }

    private func rebuildVirtualList() {
        for view in virtualListStack.arrangedSubviews {
            virtualListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if model.virtualConfigs.isEmpty {
            virtualListStack.addArrangedSubview(
                Theme.label("No virtual displays configured.", size: 10, color: .secondaryLabelColor)
            )
            return
        }
        for (index, configuration) in model.virtualConfigs.enumerated() {
            let active = model.runtime.virtualDisplays.isActive(configuration.id)
            let status = Theme.label(
                active ? "ONLINE" : "OFFLINE",
                size: 8,
                weight: .bold,
                color: active ? .systemGreen : .tertiaryLabelColor
            )
            let auto = NSButton(checkboxWithTitle: "auto", target: self, action: #selector(virtualAutoChanged(_:)))
            auto.tag = index
            auto.state = configuration.autoCreate ? .on : .off
            auto.font = .systemFont(ofSize: 9)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeVirtualPressed(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.font = .systemFont(ofSize: 9)
            remove.tag = index

            let row = Theme.horizontal(
                [
                    Theme.label(configuration.name, size: 11, weight: .medium),
                    status,
                    Theme.label(configuration.label, size: 9, color: .secondaryLabelColor),
                    Theme.flexibleSpace(),
                    auto,
                    remove,
                ],
                spacing: 8
            )
            virtualListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: virtualListStack.widthAnchor).isActive = true
        }
    }

    @objc private func createVirtualPressed() {
        let width = Int(virtualWidthField.stringValue) ?? 0
        let height = Int(virtualHeightField.stringValue) ?? 0
        let refresh = Double(virtualRefreshField.stringValue) ?? 60
        guard width >= 640, height >= 480 else {
            NSSound.beep()
            return
        }
        let name = virtualNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = VirtualDisplayConfig(
            name: name.isEmpty ? "Virtual Display" : name,
            width: width,
            height: height,
            refreshRate: max(30, min(240, refresh)),
            hiDPI: virtualHiDPIToggle.state == .on,
            autoCreate: virtualAutoToggle.state == .on
        )
        model.createVirtualDisplay(configuration)
    }

    @objc private func removeVirtualPressed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < model.virtualConfigs.count else { return }
        model.removeVirtualDisplay(id: model.virtualConfigs[sender.tag].id)
    }

    @objc private func virtualAutoChanged(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < model.virtualConfigs.count else { return }
        model.setVirtualAutoCreate(sender.state == .on, id: model.virtualConfigs[sender.tag].id)
    }

    private func aboutContent() -> NSView {
        let icon = NSImageView()
        icon.image = Theme.symbol("sun.max.fill", size: 48, weight: .regular)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = Theme.label("Nits", size: 22, weight: .semibold)
        name.alignment = .center
        let version = Theme.label("Version \(NitsVersion.current)", size: 11, color: .secondaryLabelColor)
        version.alignment = .center
        let blurb = Theme.label(
            "Free, open-source display control for macOS.\nNo license key, no telemetry, no Pro tier.",
            size: 11,
            color: .secondaryLabelColor,
            lines: 3
        )
        blurb.alignment = .center
        let capabilities = Theme.label(
            "Brightness · contrast · volume · input · HiDPI\npresets · layout · hotkeys · CLI · URL scheme",
            size: 10,
            color: .tertiaryLabelColor,
            lines: 3
        )
        capabilities.alignment = .center

        let stack = Theme.vertical([icon, name, version, blurb, capabilities], spacing: 10, alignment: .centerX)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 50),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),
        ])
        return container
    }

    // MARK: - Observation

    private func observe() {
        model.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildShortcuts()
                self?.syncControls()
            }
            .store(in: &cancellables)

        model.$presets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildShortcuts() }
            .store(in: &cancellables)

        model.$virtualConfigs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildVirtualList() }
            .store(in: &cancellables)

        model.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildGroupList() }
            .store(in: &cancellables)

        model.$rows
            .receive(on: RunLoop.main)
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildGroupMembers() }
            .store(in: &cancellables)

        model.$launchAtLogin
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.checkboxes[4]?.state = on ? .on : .off }
            .store(in: &cancellables)

        model.$keepAwake
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.checkboxes[5]?.state = on ? .on : .off }
            .store(in: &cancellables)

        model.$accessibilityTrusted
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                self?.accessibilityLabel.stringValue = trusted
                    ? "Accessibility permission granted."
                    : "Accessibility permission is required for the hardware media keys."
            }
            .store(in: &cancellables)

        model.$nightShiftOn
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.checkboxes[7]?.state = on ? .on : .off }
            .store(in: &cancellables)

        model.$trueToneOn
            .receive(on: RunLoop.main)
            .sink { [weak self] on in self?.checkboxes[8]?.state = on ? .on : .off }
            .store(in: &cancellables)
    }

    private func syncControls() {
        let settings = model.settings
        checkboxes[1]?.state = settings.showOSD ? .on : .off
        checkboxes[2]?.state = settings.restoreBrightnessOnConnect ? .on : .off
        checkboxes[3]?.state = settings.syncBrightness ? .on : .off
        checkboxes[6]?.state = settings.mediaKeysEnabled ? .on : .off
        brightnessStepLabel.stringValue = "\(Int(settings.brightnessStep))%"
        volumeStepLabel.stringValue = "\(Int(settings.volumeStep))%"
    }

    private func rebuildShortcuts() {
        for view in globalHotkeyStack.arrangedSubviews {
            globalHotkeyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in presetHotkeyStack.arrangedSubviews {
            presetHotkeyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let keys: [(String, String)] = [
            ("Brightness up", "brightnessUp"),
            ("Brightness down", "brightnessDown"),
            ("Volume up", "volumeUp"),
            ("Volume down", "volumeDown"),
            ("Toggle HiDPI", "toggleHiDPI"),
            ("Cycle input", "cycleInput"),
            ("Mute", "toggleMute"),
        ]

        for (title, key) in keys {
            let recorder = HotkeyRecorderControl(binding: model.settings.hotkeys[key]) { [weak self] binding in
                self?.model.updateGeneral { general in
                    if let binding {
                        general.hotkeys[key] = binding
                    } else {
                        general.hotkeys.removeValue(forKey: key)
                    }
                }
            }
            var views: [NSView] = [Theme.label(title, size: 11), Theme.flexibleSpace(), recorder]
            if model.settings.hotkeys[key] != nil {
                views.append(clearButton(key: key, isPreset: nil))
            }
            let row = Theme.horizontal(views, spacing: 8)
            globalHotkeyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: globalHotkeyStack.widthAnchor).isActive = true
        }

        for preset in model.presets {
            let recorder = HotkeyRecorderControl(binding: preset.hotkey) { [weak self] binding in
                self?.model.setPresetHotkey(id: preset.id, binding: binding)
            }
            let label = Theme.horizontal(
                [NSImageView(image: Theme.symbol(preset.icon, size: 10) ?? NSImage()), Theme.label(preset.name, size: 11)],
                spacing: 6
            )
            var views: [NSView] = [label, Theme.flexibleSpace(), recorder]
            if preset.hotkey != nil {
                views.append(clearButton(key: nil, isPreset: preset.id))
            }
            let row = Theme.horizontal(views, spacing: 8)
            presetHotkeyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: presetHotkeyStack.widthAnchor).isActive = true
        }

        if model.presets.isEmpty {
            presetHotkeyStack.addArrangedSubview(
                Theme.label("No presets yet — save one from the menu bar panel.", size: 10, color: .secondaryLabelColor)
            )
        }
    }

    private func clearButton(key: String?, isPreset: UUID?) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(clearHotkey(_:)))
        button.image = Theme.symbol("xmark.circle.fill", size: 10)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = "Clear shortcut"
        if let key {
            button.identifier = NSUserInterfaceItemIdentifier("key:\(key)")
        } else if let isPreset {
            button.identifier = NSUserInterfaceItemIdentifier("preset:\(isPreset.uuidString)")
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    // MARK: - Actions

    @objc private func generalToggle(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.tag {
        case 1: model.updateGeneral { $0.showOSD = on }
        case 2: model.updateGeneral { $0.restoreBrightnessOnConnect = on }
        case 3: model.updateGeneral { $0.syncBrightness = on }
        case 4: model.setLaunchAtLogin(on)
        case 5: model.setKeepAwake(on)
        case 6: model.setMediaKeys(on)
        case 7: model.setNightShift(on)
        case 8: model.setTrueTone(on)
        default: break
        }
    }

    @objc private func brightnessStepChanged(_ sender: NSStepper) {
        let value = sender.doubleValue
        brightnessStepLabel.stringValue = "\(Int(value))%"
        model.updateGeneral { $0.brightnessStep = value }
    }

    @objc private func volumeStepChanged(_ sender: NSStepper) {
        let value = sender.doubleValue
        volumeStepLabel.stringValue = "\(Int(value))%"
        model.updateGeneral { $0.volumeStep = value }
    }

    @objc private func grantAccessibility() {
        model.requestAccessibility()
    }

    @objc private func clearHotkey(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        if identifier.hasPrefix("key:") {
            let key = String(identifier.dropFirst(4))
            model.updateGeneral { $0.hotkeys.removeValue(forKey: key) }
        } else if identifier.hasPrefix("preset:"),
                  let id = UUID(uuidString: String(identifier.dropFirst(7))) {
            model.setPresetHotkey(id: id, binding: nil)
        }
    }

    @objc private func runDoctor() {
        guard let window = view.window else { return }
        let controller = doctorController ?? DoctorWindowController()
        doctorController = controller
        controller.show(text: "Collecting display, DDC and private-API state…", relativeTo: window)
        Task {
            let report = await Doctor.run(runtime: model.runtime)
            await MainActor.run {
                controller.show(text: Doctor.renderText(report), relativeTo: window)
            }
        }
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(model.runtime.config.url.deletingLastPathComponent())
    }

    @objc private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([model.runtime.config.url])
    }

    @objc private func resetImageAdjustments() {
        for row in model.rows { model.resetGamma(rowID: row.id) }
        model.showStatus("Image adjustments reset")
    }

    @objc private func refreshDDC() {
        model.runtime.ddc.invalidateAll()
        model.refreshAll(seedHardware: true)
    }
}

@MainActor
final class DoctorWindowController: NSWindowController {
    private let textView = NSTextView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Nits Diagnostics"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copy.bezelStyle = .rounded
        copy.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window.contentView else { return }
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -8),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(text: String, relativeTo parent: NSWindow?) {
        textView.string = text
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }
}

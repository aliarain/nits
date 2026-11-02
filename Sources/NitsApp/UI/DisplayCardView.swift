import AppKit
import NitsCore

@MainActor
final class DisplayCardView: CardView {
    private let model: AppModel
    private let rowID: String
    private let onPickMode: (String) -> Void

    private let nameLabel = Theme.label("", size: 12, weight: .semibold)
    private let resolutionLabel = Theme.label("", size: 10, color: .secondaryLabelColor)
    private let backendLabel = Theme.label("", size: 8, weight: .semibold, color: .secondaryLabelColor)
    private let mainBadge = Theme.badge("MAIN", color: .controlAccentColor)
    private let offBadge = Theme.badge("OFF", color: .systemOrange)
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton()

    private let brightnessIcon = NSImageView()
    private let brightnessSlider = NSSlider()
    private let brightnessValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let brightnessRow = NSStackView()

    private let volumeRow = NSStackView()
    private let volumeSlider = NSSlider()
    private let volumeValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)

    private let inputPopup = NSPopUpButton()
    private let hidpiButton = NSButton()
    private let chevronButton = NSButton()

    private let detailStack = NSStackView()
    private let resolutionButton = NSButton()
    private let scaleRow = NSStackView()
    private let scaleSlider = NSSlider()
    private let scaleValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private var scaleLadder: [DisplayModeInfo] = []
    private let contrastRow = NSStackView()
    private let contrastSlider = NSSlider()
    private let contrastValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let colorRow = NSStackView()
    private let colorPopup = NSPopUpButton()
    private var colorSignature = ""
    private let gammaSlider = NSSlider()
    private let gammaValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let softwareContrastSlider = NSSlider()
    private let softwareContrastValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let temperatureSlider = NSSlider()
    private let temperatureValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let gainSlider = NSSlider()
    private let gainValue = Theme.label("", size: 10, weight: .medium, color: .secondaryLabelColor)
    private let hdrToggle = NSButton(checkboxWithTitle: "HDR dimming", target: nil, action: nil)
    private let extraToggle = NSButton(checkboxWithTitle: "Extra brightness", target: nil, action: nil)
    private let forceVolumeButton = NSButton()
    private let disconnectButton = NSButton()
    private let resetImageButton = NSButton()

    private var lastInputSignature: String?
    private var current: DisplayRowState
    private var eventActionsController: EventActionsWindowController?

    init(model: AppModel, row: DisplayRowState, onPickMode: @escaping (String) -> Void) {
        self.model = model
        self.rowID = row.id
        self.onPickMode = onPickMode
        self.current = row
        super.init(frame: .zero)

        build()
        update(row)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var display: DisplaySnapshot { current.display }

    // MARK: - Build

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        Theme.pin(stack, to: self, insets: NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12))

        let header = buildHeaderRow()
        configureBrightnessRow()
        configureVolumeRow()
        let quick = buildQuickRow()
        buildDetail()

        let rows: [NSView] = [header, brightnessRow, volumeRow, quick, detailStack]
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func buildHeaderRow() -> NSView {
        let icon = NSImageView()
        icon.image = Theme.symbol("display", size: 15)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let nameRow = Theme.horizontal([nameLabel, mainBadge, offBadge, Theme.flexibleSpace()], spacing: 5)
        let titles = Theme.vertical([nameRow, resolutionLabel], spacing: 1)
        nameRow.widthAnchor.constraint(equalTo: titles.widthAnchor).isActive = true

        backendLabel.font = .systemFont(ofSize: 8, weight: .semibold)
        backendLabel.textColor = .tertiaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 13).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 13).isActive = true

        actionButton.image = Theme.symbol("ellipsis.circle", size: 13)
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.target = self
        actionButton.action = #selector(showActionMenu)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.widthAnchor.constraint(equalToConstant: 20).isActive = true

        return Theme.horizontal(
            [icon, titles, Theme.flexibleSpace(), backendLabel, spinner, actionButton],
            spacing: 7
        )
    }

    private func configureBrightnessRow() {
        brightnessIcon.image = Theme.symbol("sun.max.fill", size: 10)
        brightnessIcon.contentTintColor = .secondaryLabelColor
        brightnessIcon.translatesAutoresizingMaskIntoConstraints = false
        brightnessIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        configureSlider(brightnessSlider, action: #selector(brightnessChanged(_:)))
        brightnessValue.alignment = .right
        brightnessValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        brightnessValue.translatesAutoresizingMaskIntoConstraints = false
        brightnessValue.widthAnchor.constraint(equalToConstant: 46).isActive = true

        brightnessRow.orientation = .horizontal
        brightnessRow.alignment = .centerY
        brightnessRow.spacing = 8
        brightnessRow.addArrangedSubview(brightnessIcon)
        brightnessRow.addArrangedSubview(brightnessSlider)
        brightnessRow.addArrangedSubview(brightnessValue)
        brightnessRow.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureVolumeRow() {
        let icon = NSImageView()
        icon.image = Theme.symbol("speaker.wave.2.fill", size: 10)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        configureSlider(volumeSlider, action: #selector(volumeChanged(_:)))
        volumeValue.alignment = .right
        volumeValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        volumeValue.translatesAutoresizingMaskIntoConstraints = false
        volumeValue.widthAnchor.constraint(equalToConstant: 46).isActive = true

        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        volumeRow.addArrangedSubview(icon)
        volumeRow.addArrangedSubview(volumeSlider)
        volumeRow.addArrangedSubview(volumeValue)
        volumeRow.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildQuickRow() -> NSView {
        inputPopup.controlSize = .small
        inputPopup.font = .systemFont(ofSize: 10)
        inputPopup.target = self
        inputPopup.action = #selector(inputChanged(_:))
        inputPopup.translatesAutoresizingMaskIntoConstraints = false
        inputPopup.setContentHuggingPriority(.required, for: .horizontal)

        hidpiButton.title = "HiDPI"
        hidpiButton.bezelStyle = .rounded
        hidpiButton.controlSize = .small
        hidpiButton.font = .systemFont(ofSize: 10, weight: .medium)
        hidpiButton.image = Theme.symbol("rectangle.on.rectangle", size: 9)
        hidpiButton.imagePosition = .imageLeading
        hidpiButton.target = self
        hidpiButton.action = #selector(hidpiPressed)

        chevronButton.image = Theme.symbol("chevron.down", size: 9, weight: .semibold)
        chevronButton.isBordered = false
        chevronButton.imagePosition = .imageOnly
        chevronButton.target = self
        chevronButton.action = #selector(toggleDetails)
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.widthAnchor.constraint(equalToConstant: 18).isActive = true

        return Theme.horizontal(
            [inputPopup, hidpiButton, Theme.flexibleSpace(), chevronButton],
            spacing: 8
        )
    }

    private func buildDetail() {
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.isHidden = true

        resolutionButton.title = "Resolution"
        resolutionButton.bezelStyle = .recessed
        resolutionButton.controlSize = .small
        resolutionButton.font = .systemFont(ofSize: 10)
        resolutionButton.alignment = .left
        resolutionButton.image = Theme.symbol("rectangle.expand.vertical", size: 9)
        resolutionButton.imagePosition = .imageLeading
        resolutionButton.target = self
        resolutionButton.action = #selector(pickMode)
        resolutionButton.translatesAutoresizingMaskIntoConstraints = false

        let scaleIcon = NSImageView()
        scaleIcon.image = Theme.symbol("textformat.size", size: 10)
        scaleIcon.contentTintColor = .secondaryLabelColor
        scaleIcon.translatesAutoresizingMaskIntoConstraints = false
        scaleIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        scaleSlider.minValue = 0
        scaleSlider.maxValue = 1
        scaleSlider.allowsTickMarkValuesOnly = true
        scaleSlider.isContinuous = false
        scaleSlider.controlSize = .small
        scaleSlider.target = self
        scaleSlider.action = #selector(scaleChanged(_:))
        scaleSlider.translatesAutoresizingMaskIntoConstraints = false
        scaleSlider.setContentHuggingPriority(.init(1), for: .horizontal)
        scaleSlider.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        scaleValue.alignment = .right
        scaleValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        scaleValue.translatesAutoresizingMaskIntoConstraints = false
        scaleValue.widthAnchor.constraint(equalToConstant: 76).isActive = true
        scaleRow.orientation = .horizontal
        scaleRow.alignment = .centerY
        scaleRow.spacing = 8
        scaleRow.addArrangedSubview(scaleIcon)
        scaleRow.addArrangedSubview(scaleSlider)
        scaleRow.addArrangedSubview(scaleValue)
        scaleRow.translatesAutoresizingMaskIntoConstraints = false

        configureSlider(contrastSlider, action: #selector(contrastChanged(_:)))
        let contrastIcon = NSImageView()
        contrastIcon.image = Theme.symbol("circle.lefthalf.filled", size: 10)
        contrastIcon.contentTintColor = .secondaryLabelColor
        contrastIcon.translatesAutoresizingMaskIntoConstraints = false
        contrastIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        contrastValue.alignment = .right
        contrastValue.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        contrastValue.translatesAutoresizingMaskIntoConstraints = false
        contrastValue.widthAnchor.constraint(equalToConstant: 46).isActive = true

        contrastRow.orientation = .horizontal
        contrastRow.alignment = .centerY
        contrastRow.spacing = 8
        contrastRow.addArrangedSubview(contrastIcon)
        contrastRow.addArrangedSubview(contrastSlider)
        contrastRow.addArrangedSubview(contrastValue)
        contrastRow.translatesAutoresizingMaskIntoConstraints = false

        let imageTitle = Theme.label("Software image", size: 9, weight: .semibold, color: .tertiaryLabelColor)
        let gammaRow = sliderRow(
            icon: "camera.filters",
            slider: gammaSlider,
            value: gammaValue,
            action: #selector(gammaChanged(_:)),
            tag: 0
        )
        let softwareContrastRow = sliderRow(
            icon: "circle.righthalf.filled",
            slider: softwareContrastSlider,
            value: softwareContrastValue,
            action: #selector(gammaChanged(_:)),
            tag: 1
        )
        let temperatureRow = sliderRow(
            icon: "thermometer.medium",
            slider: temperatureSlider,
            value: temperatureValue,
            action: #selector(gammaChanged(_:)),
            tag: 2
        )
        let gainRow = sliderRow(
            icon: "plusminus.circle",
            slider: gainSlider,
            value: gainValue,
            action: #selector(gammaChanged(_:)),
            tag: 3
        )

        resetImageButton.title = "Reset image"
        resetImageButton.bezelStyle = .rounded
        resetImageButton.controlSize = .small
        resetImageButton.font = .systemFont(ofSize: 9)
        resetImageButton.target = self
        resetImageButton.action = #selector(resetImage)

        hdrToggle.font = .systemFont(ofSize: 10)
        hdrToggle.target = self
        hdrToggle.action = #selector(toggleHDR)
        extraToggle.font = .systemFont(ofSize: 10)
        extraToggle.target = self
        extraToggle.action = #selector(toggleExtra)

        let toggles = Theme.horizontal([hdrToggle, extraToggle, Theme.flexibleSpace()], spacing: 12)

        forceVolumeButton.title = "Force volume controls"
        forceVolumeButton.bezelStyle = .rounded
        forceVolumeButton.controlSize = .small
        forceVolumeButton.font = .systemFont(ofSize: 9)
        forceVolumeButton.target = self
        forceVolumeButton.action = #selector(forceVolume)

        disconnectButton.title = "Disconnect display"
        disconnectButton.bezelStyle = .rounded
        disconnectButton.controlSize = .small
        disconnectButton.font = .systemFont(ofSize: 9)
        disconnectButton.contentTintColor = .systemOrange
        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectPressed)

        colorPopup.controlSize = .small
        colorPopup.font = .systemFont(ofSize: 10)
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged(_:))
        colorPopup.translatesAutoresizingMaskIntoConstraints = false
        colorPopup.setContentHuggingPriority(.required, for: .horizontal)
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 8
        colorRow.addArrangedSubview(Theme.label("Color profile", size: 10))
        colorRow.addArrangedSubview(colorPopup)
        colorRow.addArrangedSubview(Theme.flexibleSpace())
        colorRow.translatesAutoresizingMaskIntoConstraints = false

        let footerRow = Theme.horizontal(
            [forceVolumeButton, disconnectButton, Theme.flexibleSpace()],
            spacing: 8
        )

        let rows: [NSView] = [
            Theme.divider(), resolutionButton, scaleRow, colorRow, contrastRow, imageTitle,
            gammaRow, softwareContrastRow, temperatureRow, gainRow,
            Theme.horizontal([resetImageButton, Theme.flexibleSpace()], spacing: 0),
            toggles, footerRow,
        ]
        for row in rows {
            detailStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
        }
    }

    private func sliderRow(
        icon: String,
        slider: NSSlider,
        value: NSTextField,
        action: Selector,
        tag: Int
    ) -> NSView {
        let image = NSImageView()
        image.image = Theme.symbol(icon, size: 10)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true

        configureSlider(slider, action: action)
        slider.tag = tag
        slider.minValue = -100
        slider.maxValue = 100
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true

        return Theme.horizontal([image, slider, value], spacing: 8)
    }

    private func configureSlider(_ slider: NSSlider, action: Selector) {
        slider.minValue = 0
        slider.maxValue = 100
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    // MARK: - Update

    func update(_ row: DisplayRowState) {
        current = row
        let display = row.display

        nameLabel.stringValue = display.name
        let refresh = row.state.currentMode.flatMap {
            $0.refreshRate > 0 ? String(format: "%.0f Hz", $0.refreshRate) : nil
        }
        let hidpi = row.state.currentMode?.isHiDPI == true ? " HiDPI" : ""
        resolutionLabel.stringValue = "\(display.resolutionLabel)\(hidpi) · \(display.connection)\(refresh.map { " · \($0)" } ?? "")"
        mainBadge.isHidden = !display.isMain
        offBadge.isHidden = !row.state.disconnected
        backendLabel.stringValue = backendName(row.state.backend)
        backendLabel.textColor = backendColor(row.state.backend)

        if row.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        actionButton.isEnabled = !row.isBusy

        brightnessIcon.image = Theme.symbol(
            row.state.extraBrightness
                ? "sun.max.trianglebadge.exclamationmark.fill"
                : "sun.max.fill",
            size: 10
        )
        brightnessSlider.maxValue = row.state.extraBrightness ? 150 : 100
        brightnessSlider.doubleValue = row.brightness ?? 0
        brightnessValue.stringValue = row.brightness.map { "\(Int($0.rounded()))%" } ?? "—"

        volumeRow.isHidden = !row.volumeSupported
        volumeSlider.doubleValue = row.volume ?? 0
        volumeValue.stringValue = row.volume.map { "\(Int($0.rounded()))%" } ?? "—"

        updateInputs(row)
        updateColorPopup(row)
        hidpiButton.title = row.state.currentMode?.isHiDPI == true ? "HiDPI" : "HiDPI"

        detailStack.isHidden = !row.isExpanded
        chevronButton.image = Theme.symbol(
            row.isExpanded ? "chevron.up" : "chevron.down",
            size: 9,
            weight: .semibold
        )
        resolutionButton.title = "Resolution   \(row.state.currentMode?.label ?? "Choose…")"
        updateScale(row)

        contrastRow.isHidden = row.contrast == nil || display.isBuiltin
        if let contrast = row.contrast {
            contrastSlider.doubleValue = contrast
            contrastValue.stringValue = "\(Int(contrast.rounded()))%"
        }

        if row.isExpanded {
            gammaSlider.doubleValue = row.gamma.gamma
            gammaValue.stringValue = "γ \(Int(row.gamma.gamma.rounded()))"
            softwareContrastSlider.doubleValue = row.gamma.contrast
            softwareContrastValue.stringValue = "C \(Int(row.gamma.contrast.rounded()))"
            temperatureSlider.doubleValue = row.gamma.colorTemperature
            temperatureValue.stringValue = "T \(Int(row.gamma.colorTemperature.rounded()))"
            gainSlider.doubleValue = row.gamma.gain
            gainValue.stringValue = "G \(Int(row.gamma.gain.rounded()))"
        }

        hdrToggle.state = row.state.hdrSoftware ? .on : .off
        extraToggle.state = row.state.extraBrightness ? .on : .off
        forceVolumeButton.isHidden = display.isBuiltin || row.volumeSupported
        disconnectButton.isHidden = display.isBuiltin
        inputPopup.isHidden = display.isBuiltin
    }

    private func updateInputs(_ row: DisplayRowState) {
        let signature = (row.inputs?.map(\.value) ?? []) + [row.currentInput ?? 0]
        let signatureText = signature.map(String.init).joined(separator: ",")
        guard signatureText != lastInputSignature else { return }
        lastInputSignature = signatureText

        inputPopup.removeAllItems()
        if let inputs = row.inputs {
            for input in inputs {
                inputPopup.addItem(withTitle: input.name)
                inputPopup.lastItem?.representedObject = NSNumber(value: input.value)
                inputPopup.lastItem?.state = input.value == row.currentInput ? .on : .off
            }
            if let current = row.currentInput,
               let index = row.inputs?.firstIndex(where: { $0.value == current }) {
                inputPopup.selectItem(at: index)
            }
            inputPopup.menu?.addItem(.separator())
            let refresh = NSMenuItem(title: "Refresh inputs", action: nil, keyEquivalent: "")
            refresh.tag = 999
            inputPopup.menu?.addItem(refresh)
        } else {
            inputPopup.addItem(withTitle: "Load inputs…")
            inputPopup.lastItem?.tag = 999
        }
    }

    private func updateColorPopup(_ row: DisplayRowState) {
        let paths = row.profiles?.map(\.path.path).joined(separator: "|") ?? "nil"
        let signature = "\(row.currentProfileName ?? "")|\(paths)"
        guard signature != colorSignature else { return }
        colorSignature = signature

        colorPopup.removeAllItems()
        colorPopup.addItem(withTitle: row.currentProfileName ?? "Current profile")
        colorPopup.lastItem?.isEnabled = false
        colorPopup.menu?.addItem(.separator())

        if let profiles = row.profiles {
            for profile in profiles {
                colorPopup.addItem(withTitle: profile.name)
                colorPopup.lastItem?.representedObject = profile.path.path
            }
            if profiles.isEmpty {
                colorPopup.addItem(withTitle: "No display profiles found")
                colorPopup.lastItem?.isEnabled = false
            }
        } else {
            colorPopup.addItem(withTitle: "Load profiles…")
            colorPopup.lastItem?.tag = 999
        }
        colorPopup.selectItem(at: 0)
    }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == 999 || sender.selectedItem?.representedObject == nil {
            model.loadColorProfiles(rowID: rowID)
            return
        }
        guard let path = sender.selectedItem?.representedObject as? String,
              let profile = current.profiles?.first(where: { $0.path.path == path })
        else { return }
        model.setColorProfile(profile, rowID: rowID)
    }

    private func backendName(_ backend: BrightnessBackend) -> String {
        switch backend {
        case .native: return "SYSTEM"
        case .ddc: return "DDC"
        case .software: return "SOFTWARE"
        case .hdrSoftware: return "HDR"
        case .unknown: return "?"
        }
    }

    private func backendColor(_ backend: BrightnessBackend) -> NSColor {
        switch backend {
        case .ddc, .native: return .systemGreen
        case .software, .hdrSoftware: return .systemOrange
        case .unknown: return .tertiaryLabelColor
        }
    }

    // MARK: - Actions

    @objc private func brightnessChanged(_ sender: NSSlider) {
        brightnessValue.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        model.setBrightness(sender.doubleValue, rowID: rowID)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        volumeValue.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        model.setVolume(sender.doubleValue, rowID: rowID)
    }

    private func updateScale(_ row: DisplayRowState) {
        guard row.isExpanded, !row.isBusy, let mode = row.state.currentMode,
              let (ladder, index) = model.runtime.scaleLadder(for: row.display),
              ladder.count > 1
        else {
            scaleRow.isHidden = true
            return
        }
        scaleRow.isHidden = false
        if ladder != scaleLadder {
            scaleLadder = ladder
            scaleSlider.maxValue = Double(ladder.count - 1)
            scaleSlider.numberOfTickMarks = ladder.count
        }
        scaleSlider.doubleValue = Double(index)
        scaleValue.stringValue = "\(mode.width)×\(mode.height)"
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        let index = Int(sender.doubleValue.rounded())
        guard scaleLadder.indices.contains(index) else { return }
        let mode = scaleLadder[index]
        scaleValue.stringValue = "\(mode.width)×\(mode.height)"
        model.setMode(mode, rowID: rowID)
    }

    @objc private func contrastChanged(_ sender: NSSlider) {
        contrastValue.stringValue = "\(Int(sender.doubleValue.rounded()))%"
        model.setContrast(sender.doubleValue, rowID: rowID)
    }

    @objc private func gammaChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        switch sender.tag {
        case 0:
            gammaValue.stringValue = "γ \(Int(value.rounded()))"
            model.modifyGamma(rowID: rowID) { $0.gamma = value }
        case 1:
            softwareContrastValue.stringValue = "C \(Int(value.rounded()))"
            model.modifyGamma(rowID: rowID) { $0.contrast = value }
        case 2:
            temperatureValue.stringValue = "T \(Int(value.rounded()))"
            model.modifyGamma(rowID: rowID) { $0.colorTemperature = value }
        default:
            gainValue.stringValue = "G \(Int(value.rounded()))"
            model.modifyGamma(rowID: rowID) { $0.gain = value }
        }
    }

    @objc private func resetImage() {
        model.resetGamma(rowID: rowID)
    }

    @objc private func toggleHDR() {
        model.toggleHDRSoftware(rowID: rowID)
    }

    @objc private func toggleExtra() {
        model.toggleExtraBrightness(rowID: rowID)
    }

    @objc private func toggleDetails() {
        model.toggleExpanded(rowID: rowID)
    }

    @objc private func hidpiPressed() {
        model.toggleHiDPI(rowID: rowID)
    }

    @objc private func pickMode() {
        onPickMode(rowID)
    }

    @objc private func inputChanged(_ sender: NSPopUpButton) {
        if sender.selectedItem?.tag == 999 || sender.selectedItem?.representedObject == nil {
            model.loadInputs(rowID: rowID)
            return
        }
        guard let value = (sender.selectedItem?.representedObject as? NSNumber)?.uint16Value else {
            return
        }
        model.setInput(value, rowID: rowID)
    }

    @objc private func forceVolume() {
        model.runtime.setForcedVolume(true, for: display)
        model.showStatus("Volume controls enabled for \(display.name)")
        model.refreshAll(seedHardware: true)
    }

    @objc private func disconnectPressed() {
        model.disconnect(rowID: rowID)
    }

    @objc private func showActionMenu() {
        let menu = NSMenu()

        func item(_ title: String, _ tag: Int, _ submenu: NSMenu? = nil) {
            let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = tag
            menuItem.submenu = submenu
            menu.addItem(menuItem)
        }

        item("Refresh", 1)
        item("Set as Main Display", 2)
        item("Rename Display…", 400)
        if model.runtime.config.snapshot().displaySettings[display.uuid]?.customName != nil {
            item("Use Monitor Name", 401)
        }
        item("Set Current Resolution as Default", 402)
        if model.runtime.config.snapshot().displaySettings[display.uuid]?.defaultMode != nil {
            item("Clear Default Resolution", 403)
        }
        item("Event Actions…", 404)
        menu.addItem(.separator())

        let rotate = NSMenu()
        for degrees in [0, 90, 180, 270] {
            let rotateItem = NSMenuItem(
                title: "\(degrees)°",
                action: #selector(menuAction(_:)),
                keyEquivalent: ""
            )
            rotateItem.target = self
            rotateItem.tag = 100 + degrees
            rotate.addItem(rotateItem)
        }
        item("Rotate", 0, rotate)

        let hidpi = NSMenu()
        for (title, tag) in [
            ("Enable standard HiDPI…", 200),
            ("Enable smooth scaling…", 201),
            ("Remove HiDPI override", 202),
        ] {
            let sub = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            sub.target = self
            sub.tag = tag
            hidpi.addItem(sub)
        }
        item("HiDPI", 0, hidpi)

        if !display.isBuiltin {
            menu.addItem(.separator())
            item("Disconnect Display", 300)
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: actionButton.bounds.width, y: actionButton.bounds.height),
            in: actionButton
        )
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: model.refreshControls(rowID: rowID)
        case 2: model.setMain(rowID: rowID)
        case 100...103: model.rotate(rowID: rowID, degrees: sender.tag - 100)
        case 200: model.enableHiDPI(rowID: rowID, dense: false)
        case 201: model.enableHiDPI(rowID: rowID, dense: true)
        case 202: model.disableHiDPI(rowID: rowID)
        case 300: model.disconnect(rowID: rowID)
        case 400: promptRename()
        case 401: model.rename(rowID: rowID, name: nil)
        case 402: model.setDefaultResolution(rowID: rowID)
        case 403: model.clearDefaultResolution(rowID: rowID)
        case 404: showEventActions()
        default: break
        }
    }

    private func showEventActions() {
        let controller = EventActionsWindowController(model: model, display: display)
        eventActionsController = controller
        controller.show()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename Display"
        alert.informativeText = "This name is stored by Nits and does not change the monitor."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = display.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.rename(rowID: rowID, name: field.stringValue)
        }
    }
}

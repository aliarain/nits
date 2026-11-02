import AppKit
import NitsCore

/// A button that records the next key combination with at least one modifier.
/// Escape clears the binding. Uses a local monitor, so it works anywhere in the app.
@MainActor
final class HotkeyRecorderControl: NSButton {
    var binding: HotkeyBinding? {
        didSet { updateTitle() }
    }
    var onChange: ((HotkeyBinding?) -> Void)?

    private var monitor: Any?

    init(binding: HotkeyBinding?, onChange: @escaping (HotkeyBinding?) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        self.binding = binding
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 10, weight: .medium)
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func updateTitle() {
        title = binding?.label ?? "Record"
    }

    @objc private func toggleRecording() {
        if monitor != nil {
            stopRecording()
            return
        }
        title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.binding = nil
                self.onChange?(nil)
                self.stopRecording()
                return nil
            }
            let modifiers = KeyboardShortcuts.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else {
                NSSound.beep()
                return nil
            }
            let captured = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                label: KeyboardShortcuts.label(for: event)
            )
            self.binding = captured
            self.onChange?(captured)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        updateTitle()
    }
}

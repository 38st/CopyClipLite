import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    let config: HotkeyConfig
    let onChange: (HotkeyConfig) -> Void
    let onRecordingChanged: (Bool) -> Void

    init(
        config: HotkeyConfig,
        onChange: @escaping (HotkeyConfig) -> Void,
        onRecordingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.config = config
        self.onChange = onChange
        self.onRecordingChanged = onRecordingChanged
    }

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.config = config
        view.onChange = { newConfig in
            onChange(newConfig)
        }
        view.onRecordingChanged = onRecordingChanged
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        nsView.config = config
        nsView.onRecordingChanged = onRecordingChanged
        nsView.refreshLabel()
    }
}

final class HotkeyRecorderView: NSButton {
    var config: HotkeyConfig = .default
    var onChange: ((HotkeyConfig) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 13, weight: .medium)
        focusRingType = .default
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("Global hotkey")
        setAccessibilityHelp("Press to record a new keyboard shortcut. Press Escape to cancel.")
        refreshLabel()
    }

    override var canBecomeKeyView: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press a key combination…"
        setAccessibilityValue("Recording")
        window?.makeFirstResponder(self)
        onRecordingChanged?(true)
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == kVK_Escape {
            finishRecording()
            return
        }

        let keyCode = Int(event.keyCode)
        var modifiers = 0
        if event.modifierFlags.contains(.command) { modifiers |= cmdKey }
        if event.modifierFlags.contains(.option) { modifiers |= optionKey }
        if event.modifierFlags.contains(.control) { modifiers |= controlKey }
        if event.modifierFlags.contains(.shift) { modifiers |= shiftKey }

        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        let newConfig = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
        if let validationError = newConfig.validationError {
            NSSound.beep()
            setAccessibilityValue(validationError.localizedDescription)
            return
        }

        config = newConfig
        onChange?(newConfig)
        finishRecording()
    }

    func refreshLabel() {
        if isRecording {
            return
        }
        title = config.displayString
        setAccessibilityValue(config.displayString)
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        refreshLabel()
        onRecordingChanged?(false)
    }
}

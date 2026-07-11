import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorder: NSViewRepresentable {
    let config: HotkeyConfig
    let onChange: (HotkeyConfig) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView()
        view.config = config
        view.onChange = { newConfig in
            onChange(newConfig)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        nsView.config = config
        nsView.refreshLabel()
    }
}

final class HotkeyRecorderView: NSButton {
    var config: HotkeyConfig = .default
    var onChange: ((HotkeyConfig) -> Void)?

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
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        refreshLabel()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == kVK_Escape {
            isRecording = false
            refreshLabel()
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
        config = newConfig
        isRecording = false
        refreshLabel()
        onChange?(newConfig)
    }

    func refreshLabel() {
        if isRecording {
            return
        }
        title = config.displayString
        setAccessibilityValue(config.displayString)
    }
}

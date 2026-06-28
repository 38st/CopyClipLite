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

final class HotkeyRecorderView: NSView {
    var config: HotkeyConfig = .default
    var onChange: ((HotkeyConfig) -> Void)?

    private let label = NSTextField(labelWithString: "")
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
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.isBezeled = true
        label.bezelStyle = .roundedBezel
        label.drawsBackground = true
        label.backgroundColor = .controlBackgroundColor
        label.focusRingType = .none
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshLabel()
    }

    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        label.stringValue = "Press a key combination…"
        label.backgroundColor = NSColor.selectedControlColor
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        label.backgroundColor = .controlBackgroundColor
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
            label.backgroundColor = .controlBackgroundColor
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
        label.backgroundColor = .controlBackgroundColor
        refreshLabel()
        onChange?(newConfig)
    }

    func refreshLabel() {
        if isRecording {
            return
        }
        label.stringValue = config.displayString
    }
}

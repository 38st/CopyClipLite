import AppKit
import CoreGraphics

enum PasteSimulator {
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
    }

    static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    @discardableResult
    static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: true
        )
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        guard let keyDown, let keyUp else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

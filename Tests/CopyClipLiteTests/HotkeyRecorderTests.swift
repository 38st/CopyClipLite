import AppKit
import Carbon
import XCTest
@testable import CopyClipLite

@MainActor
final class HotkeyRecorderTests: XCTestCase {
    func testDismantlingActiveRecorderEndsRecordingExactlyOnce() {
        let view = HotkeyRecorderView()
        var recordingChanges: [Bool] = []
        view.onRecordingChanged = { recordingChanges.append($0) }

        view.performClick(nil)
        XCTAssertEqual(recordingChanges, [true])

        HotkeyRecorder.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(recordingChanges, [true, false])

        HotkeyRecorder.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(recordingChanges, [true, false])
    }

    func testClosingHostingWindowEndsRecording() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        let view = HotkeyRecorderView()
        var recordingChanges: [Bool] = []
        view.onRecordingChanged = { recordingChanges.append($0) }
        window.contentView = view
        view.performClick(nil)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        XCTAssertEqual(recordingChanges, [true, false])
    }

    func testMissingModifierShowsVisibleAndAccessibleGuidance() throws {
        let view = HotkeyRecorderView()
        view.performClick(nil)

        view.keyDown(with: try keyEvent(keyCode: UInt16(kVK_ANSI_A), characters: "a"))

        XCTAssertEqual(view.title, "Add ⌘, ⌥, or ⌃")
        XCTAssertEqual(
            view.accessibilityValue() as? String,
            "Add Command, Option, or Control to the shortcut."
        )
    }

    func testUnsafeShortcutShowsVisibleAndAccessibleGuidance() throws {
        let view = HotkeyRecorderView()
        view.performClick(nil)

        view.keyDown(
            with: try keyEvent(
                keyCode: UInt16(kVK_ANSI_A),
                characters: "a",
                modifiers: .command
            )
        )

        XCTAssertEqual(view.title, "Add another modifier")
        XCTAssertEqual(
            view.accessibilityValue() as? String,
            HotkeyConfigValidationError.unsafeEditingShortcut.localizedDescription
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

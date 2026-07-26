import AppKit
import Carbon
import XCTest
@testable import CopyClipLite

final class ClipboardPanelKeyboardBridgeTests: XCTestCase {
    func testRoutesEverySupportedKeyVariant() {
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, ClipboardPanelKeyAction)] = [
            (UInt16(kVK_DownArrow), nil, [], .moveDown),
            (UInt16(kVK_UpArrow), nil, [], .moveUp),
            (UInt16(kVK_Return), nil, [], .copySelected),
            (UInt16(kVK_ANSI_KeypadEnter), nil, [], .copySelected),
            (UInt16(kVK_Delete), nil, [], .deleteSelected),
            (UInt16(kVK_ForwardDelete), nil, [], .deleteSelected),
            (UInt16(kVK_ANSI_P), "p", [], .togglePinSelected),
            (UInt16(kVK_ANSI_F), "f", .command, .focusSearch),
            (UInt16(kVK_ANSI_P), "p", .command, .togglePinSelected),
            (UInt16(kVK_Delete), nil, .command, .deleteSelected),
            (UInt16(kVK_ForwardDelete), nil, .command, .deleteSelected),
        ]

        for (keyCode, characters, modifiers, expectedAction) in cases {
            let action = ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: keyCode,
                    characters: characters,
                    modifiers: modifiers
                )
            )

            XCTAssertEqual(
                action,
                expectedAction,
                "Unexpected action for keyCode \(keyCode), modifiers \(modifiers)"
            )
        }
    }

    func testTextEditingExcludesUnmodifiedPinAndDelete() {
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "p",
                    isEditingText: true
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_Delete), isEditingText: true)
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ForwardDelete), isEditingText: true)
            )
        )
    }

    func testTextEditingStillAllowsListNavigationUseAndExplicitCommands() {
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, ClipboardPanelKeyAction)] = [
            (UInt16(kVK_DownArrow), nil, [], .moveDown),
            (UInt16(kVK_UpArrow), nil, [], .moveUp),
            (UInt16(kVK_Return), nil, [], .copySelected),
            (UInt16(kVK_ANSI_KeypadEnter), nil, [], .copySelected),
            (UInt16(kVK_ANSI_P), "p", .command, .togglePinSelected),
            (UInt16(kVK_Delete), nil, .command, .deleteSelected),
            (UInt16(kVK_ForwardDelete), nil, .command, .deleteSelected),
            (UInt16(kVK_ANSI_F), "f", .command, .focusSearch),
        ]

        for (keyCode, characters, modifiers, expectedAction) in cases {
            XCTAssertEqual(
                ClipboardPanelKeyRouting.action(
                    for: input(
                        keyCode: keyCode,
                        characters: characters,
                        modifiers: modifiers,
                        isEditingText: true
                    )
                ),
                expectedAction
            )
        }
    }

    func testIgnoresCapsLockNumericPadAndFunctionForCommandShortcuts() {
        let irrelevantFlags: NSEvent.ModifierFlags = [
            .capsLock,
            .numericPad,
            .function,
        ]

        XCTAssertEqual(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "F",
                    modifiers: [.command, irrelevantFlags]
                )
            ),
            .focusSearch
        )
        XCTAssertEqual(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "P",
                    modifiers: [.command, irrelevantFlags],
                    isEditingText: true
                )
            ),
            .togglePinSelected
        )
    }

    func testRejectsUnsupportedModifiersAndUnknownKeys() {
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "f",
                    modifiers: [.command, .shift]
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "p",
                    modifiers: .option
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ANSI_A), characters: "a")
            )
        )
    }

    func testHandledReturnMatchesHandlerAndUnhandledEventsPropagate() {
        let recognized = input(keyCode: UInt16(kVK_DownArrow))
        var receivedActions: [ClipboardPanelKeyAction] = []

        XCTAssertTrue(
            ClipboardPanelKeyRouting.handle(recognized) { action in
                receivedActions.append(action)
                return true
            }
        )
        XCTAssertEqual(receivedActions, [.moveDown])

        XCTAssertFalse(
            ClipboardPanelKeyRouting.handle(recognized) { action in
                receivedActions.append(action)
                return false
            }
        )
        XCTAssertEqual(receivedActions, [.moveDown, .moveDown])

        let unknown = input(keyCode: UInt16(kVK_ANSI_A), characters: "a")
        XCTAssertFalse(
            ClipboardPanelKeyRouting.handle(unknown) { _ in
                XCTFail("An unrecognized event must not invoke the action handler")
                return true
            }
        )
    }

    private func input(
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        isEditingText: Bool = false
    ) -> ClipboardPanelKeyInput {
        ClipboardPanelKeyInput(
            keyCode: keyCode,
            charactersIgnoringModifiers: characters,
            modifierFlags: modifiers,
            isEditingText: isEditingText
        )
    }
}

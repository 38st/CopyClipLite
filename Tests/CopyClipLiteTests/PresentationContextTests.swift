import XCTest
@testable import CopyClipLite

final class PresentationContextTests: XCTestCase {
    func testOnlyMenuBarPanelShowsOpenMainWindowControl() {
        XCTAssertTrue(ClipboardPanelPresentationContext.menuBar.showsOpenMainWindowButton)
        XCTAssertFalse(ClipboardPanelPresentationContext.mainWindow.showsOpenMainWindowButton)
    }

    func testOnlyMenuBarPresentationResetsSearchAndFilterState() {
        XCTAssertTrue(ClipboardPanelPresentationContext.menuBar.resetsSearchOnPresentation)
        XCTAssertFalse(ClipboardPanelPresentationContext.mainWindow.resetsSearchOnPresentation)
    }

    func testWelcomeUsesActiveShortcutFormatter() {
        XCTAssertEqual(
            WelcomeContent.hotkeyDetail(isRegistered: true, displayString: "⌃⌥K"),
            "Use the menu bar or press ⌃⌥K."
        )
    }

    func testWelcomeDoesNotPromiseUnavailableShortcut() {
        let detail = WelcomeContent.hotkeyDetail(
            isRegistered: false,
            displayString: "⌥⌘V"
        )

        XCTAssertFalse(detail.contains("⌥⌘V"))
        XCTAssertTrue(detail.contains("unavailable"))
    }
}

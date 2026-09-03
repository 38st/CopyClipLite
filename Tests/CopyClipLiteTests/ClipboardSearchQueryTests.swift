import Foundation
import XCTest

@testable import CopyClipLite

final class ClipboardSearchQueryTests: XCTestCase {
    func testPlainQueryKeepsSearchingContentAndSourceTogether() {
        let item = ClipboardItem(
            text: "Quarterly notes",
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.example.Notes",
                name: "Notes"
            )
        )

        XCTAssertTrue(ClipboardSearchQuery("quarterly").matches(item))
        XCTAssertTrue(ClipboardSearchQuery("notes").matches(item))
        XCTAssertFalse(ClipboardSearchQuery("mail").matches(item))
    }

    func testAppScopeFiltersByApplicationThenSearchesClipContents() {
        let safariReceipt = ClipboardItem(
            text: "Receipt number 42",
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.apple.Safari",
                name: "Safari"
            )
        )
        let notesReceipt = ClipboardItem(
            text: "Receipt number 99",
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.apple.Notes",
                name: "Notes"
            )
        )
        let query = ClipboardSearchQuery("app:saf receipt")

        XCTAssertTrue(query.matches(safariReceipt))
        XCTAssertFalse(query.matches(notesReceipt))
        XCTAssertFalse(ClipboardSearchQuery("app:saf notes").matches(safariReceipt))
    }

    func testQuotedAppScopeSupportsApplicationNamesWithSpaces() {
        let item = ClipboardItem(
            text: "build output",
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.microsoft.VSCode",
                name: "Visual Studio Code"
            )
        )
        let query = ClipboardSearchQuery(#"app:"Visual Studio" build"#)

        XCTAssertEqual(query.applicationName, "Visual Studio")
        XCTAssertEqual(query.freeText, "build")
        XCTAssertTrue(query.matches(item))
    }

    func testEmptyAppPrefixRemainsAnOrdinaryPlainQuery() {
        let query = ClipboardSearchQuery("app:")

        XCTAssertNil(query.applicationName)
        XCTAssertEqual(query.freeText, "app:")
    }
}

import Foundation
import XCTest
@testable import CopyClipLite

final class ClipboardPanelOrderingTests: XCTestCase {
    func testDisplayedItemsPlacePinnedBeforeRecentWhilePreservingSectionOrder() {
        let newestRecent = ClipboardItem(
            text: "newest recent",
            lastCopiedAt: Date(timeIntervalSince1970: 30)
        )
        let olderPinned = ClipboardItem(
            text: "older pinned",
            lastCopiedAt: Date(timeIntervalSince1970: 20),
            isPinned: true
        )
        let oldestRecent = ClipboardItem(
            text: "oldest recent",
            lastCopiedAt: Date(timeIntervalSince1970: 10)
        )

        let displayed = ClipboardPanelOrdering.displayedItems([
            newestRecent,
            olderPinned,
            oldestRecent
        ])

        XCTAssertEqual(
            displayed.map(\.text),
            ["older pinned", "newest recent", "oldest recent"]
        )
    }
}

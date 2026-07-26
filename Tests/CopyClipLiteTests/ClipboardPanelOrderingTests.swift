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

    func testDeletingUnselectedRowPreservesSelection() {
        let first = ClipboardItem(text: "first")
        let second = ClipboardItem(text: "second")
        let third = ClipboardItem(text: "third")

        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: third.id,
                selectedID: second.id,
                before: [first, second, third],
                after: [first, second]
            ),
            second.id
        )
    }

    func testDeletingSelectedRowChoosesNextThenPreviousAtEnd() {
        let first = ClipboardItem(text: "first")
        let second = ClipboardItem(text: "second")
        let third = ClipboardItem(text: "third")

        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: second.id,
                selectedID: second.id,
                before: [first, second, third],
                after: [first, third]
            ),
            third.id
        )
        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: third.id,
                selectedID: third.id,
                before: [first, third],
                after: [first]
            ),
            first.id
        )
    }
}

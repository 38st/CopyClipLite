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

    func testDeletingSelectedFirstRowChoosesNewFirstRow() {
        let first = ClipboardItem(text: "first")
        let second = ClipboardItem(text: "second")
        let third = ClipboardItem(text: "third")

        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: first.id,
                selectedID: first.id,
                before: [first, second, third],
                after: [second, third]
            ),
            second.id
        )
    }

    func testDeletingAcrossPinnedHistoryBoundaryUsesDisplayedNeighbor() {
        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let firstHistory = ClipboardItem(text: "first history")
        let secondHistory = ClipboardItem(text: "second history")
        let before = ClipboardPanelOrdering.displayedItems([
            firstHistory,
            pinned,
            secondHistory,
        ])
        let afterDeletingPinned = ClipboardPanelOrdering.displayedItems([
            firstHistory,
            secondHistory,
        ])

        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: pinned.id,
                selectedID: pinned.id,
                before: before,
                after: afterDeletingPinned
            ),
            firstHistory.id
        )

        let afterDeletingFirstHistory = ClipboardPanelOrdering.displayedItems([
            pinned,
            secondHistory,
        ])
        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: firstHistory.id,
                selectedID: firstHistory.id,
                before: before,
                after: afterDeletingFirstHistory
            ),
            secondHistory.id
        )
    }

    func testDeletingEveryDisplayedPositionChoosesTheIntuitiveNeighbor() {
        let first = ClipboardItem(text: "first", isPinned: true)
        let second = ClipboardItem(text: "second", isPinned: true)
        let third = ClipboardItem(text: "third")
        let fourth = ClipboardItem(text: "fourth")
        let before = [first, second, third, fourth]

        let cases: [(ClipboardItem, [ClipboardItem], ClipboardItem.ID?)] = [
            (first, [second, third, fourth], second.id),
            (second, [first, third, fourth], third.id),
            (third, [first, second, fourth], fourth.id),
            (fourth, [first, second, third], third.id),
        ]

        for (deleted, after, expectedSelection) in cases {
            XCTAssertEqual(
                ClipboardPanelOrdering.selectionAfterDeleting(
                    deletedID: deleted.id,
                    selectedID: deleted.id,
                    before: before,
                    after: after
                ),
                expectedSelection,
                "Unexpected neighbor after deleting \(deleted.text)"
            )
        }
    }

    func testDeletingAnUnselectedRowAcrossASectionBoundaryPreservesSelection() {
        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let firstHistory = ClipboardItem(text: "first history")
        let secondHistory = ClipboardItem(text: "second history")

        XCTAssertEqual(
            ClipboardPanelOrdering.selectionAfterDeleting(
                deletedID: firstHistory.id,
                selectedID: pinned.id,
                before: [pinned, firstHistory, secondHistory],
                after: [pinned, secondHistory]
            ),
            pinned.id
        )
    }

    func testCopyInducedReorderRequestsScrollForSelectedRow() {
        let selected = ClipboardItem(text: "selected")
        let newer = ClipboardItem(text: "newer")
        let older = ClipboardItem(text: "older")

        XCTAssertTrue(
            ClipboardPanelOrdering.selectedPositionChanged(
                selectedID: selected.id,
                beforeIDs: [newer.id, selected.id, older.id],
                afterIDs: [selected.id, newer.id, older.id]
            )
        )
    }

    func testUnchangedSelectedPositionDoesNotRequestRedundantScroll() {
        let selected = ClipboardItem(text: "selected")
        let other = ClipboardItem(text: "other")

        XCTAssertFalse(
            ClipboardPanelOrdering.selectedPositionChanged(
                selectedID: selected.id,
                beforeIDs: [selected.id, other.id],
                afterIDs: [selected.id, other.id]
            )
        )
        XCTAssertFalse(
            ClipboardPanelOrdering.selectedPositionChanged(
                selectedID: nil,
                beforeIDs: [selected.id, other.id],
                afterIDs: [other.id, selected.id]
            )
        )
    }
}

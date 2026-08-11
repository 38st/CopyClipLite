import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testInitializationPrunesExpiredUnpinnedItemsButKeepsPinnedItems() throws {
        let now = Date()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "expired", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            ClipboardItem(
                text: "pinned", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                isPinned: true),
            ClipboardItem(text: "recent", lastCopiedAt: now.addingTimeInterval(-60)),
        ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )

        XCTAssertEqual(Set(store.items.map(\.text)), ["pinned", "recent"])
    }

    func testHistoryLimitTrimsOnlyUnpinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<12).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(
            clips + [
                ClipboardItem(
                    text: "pinned", lastCopiedAt: now.addingTimeInterval(-1_000), isPinned: true)
            ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )

        store.setHistoryLimit(10)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)
        XCTAssertTrue(store.items.contains { $0.text == "pinned" })
    }

    func testTogglePinDoesNotTrimJustUnpinnedItem() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<10).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(
            clips + [
                ClipboardItem(text: "pinned", lastCopiedAt: now, isPinned: true)
            ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        store.setHistoryLimit(10)

        guard let pinnedItem = store.items.first(where: { $0.text == "pinned" }) else {
            XCTFail("Pinned item should exist")
            return
        }

        store.togglePin(pinnedItem)

        XCTAssertTrue(store.items.contains { $0.text == "pinned" })
    }

    func testRequiredPasteboardWriteFailureDoesNotMutateHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "hello")])
        let writer = StubPasteboardWriter(result: .failure)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)

        XCTAssertFalse(store.copy(item))
        XCTAssertEqual(store.items.first?.copyCount, 1)
        XCTAssertEqual(writer.requests.count, 1)
        XCTAssertNotNil(store.storageErrorMessage)
    }

    func testRequiredPasteboardRepresentationFailureMatrixDoesNotMutateHistory() throws {
        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([ClipboardItem(text: "plain")])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeDefaults(),
                pasteboardWriter: writer
            )
            let item = try XCTUnwrap(store.items.first)

            XCTAssertFalse(store.copy(item))
            XCTAssertEqual(store.items, [item])
            XCTAssertEqual(
                writer.requests.first?.required.map(\.type),
                [NSPasteboard.PasteboardType.string.rawValue]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }

        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([ClipboardItem(text: "mixed case")])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeDefaults(),
                pasteboardWriter: writer
            )
            let itemsBeforeCopy = store.items

            store.copyWithTransformation(
                try XCTUnwrap(store.items.first),
                transformation: .uppercase
            )

            XCTAssertEqual(store.items, itemsBeforeCopy)
            XCTAssertEqual(
                writer.requests.first?.required,
                [
                    ClipboardPasteboardRepresentation(
                        .string,
                        value: .string("MIXED CASE")
                    )
                ]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }

        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([
                ClipboardItem(
                    image: ClipboardImagePayload(
                        data: try makePNGData(width: 2, height: 2),
                        width: 2,
                        height: 2
                    )
                )
            ])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.png.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeDefaults(),
                pasteboardWriter: writer
            )
            let item = try XCTUnwrap(store.items.first)

            XCTAssertFalse(store.copy(item))
            XCTAssertEqual(store.items, [item])
            XCTAssertEqual(
                writer.requests.first?.required.map(\.type),
                [NSPasteboard.PasteboardType.png.rawValue]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }
    }

    func testSuccessfulCopyClearsOnlyTheResolvedPasteboardWriteWarning() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "rich",
                rtfData: Data("rtf".utf8)
            )
        ])
        let writer = StubPasteboardWriter(
            result: .degraded(optionalTypes: [NSPasteboard.PasteboardType.rtf.rawValue])
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(String(repeating: "x", count: 20_001), forType: .string))
        store.pollPasteboardForChanges()
        let independentCaptureWarning = try XCTUnwrap(store.captureWarning)
        let item = try XCTUnwrap(store.items.first)

        XCTAssertTrue(store.copy(item))
        XCTAssertNotNil(store.pasteboardWriteWarning)
        XCTAssertEqual(store.captureWarning, independentCaptureWarning)

        writer.result = .success
        XCTAssertTrue(store.copy(item))

        XCTAssertNil(store.pasteboardWriteWarning)
        XCTAssertEqual(store.captureWarning, independentCaptureWarning)
    }

    func testManualClearRemovesPinnedAndUnpinnedItemsWhenRetentionIsDisabled() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(false, forKey: "keepPinnedOnClear")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )

        store.clearHistory()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(storage.load().isEmpty)
    }

    func testUnpinningAtHistoryLimitTrimsExcessItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<10).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        let pinnedClip = ClipboardItem(text: "pinned", lastCopiedAt: now, isPinned: true)
        storage.save(clips + [pinnedClip])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        store.setHistoryLimit(10)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)

        store.togglePin(pinnedClip)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)
        XCTAssertTrue(store.items.contains { $0.text == "pinned" && !$0.isPinned })
    }

    func testSuccessfulTransformedCopyClearsOnlyItsStorageIssue() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "recover me")])
        let writer = StubPasteboardWriter(result: .failure)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        store.copyWithTransformation(item, transformation: .uppercase)
        XCTAssertNotNil(store.storageErrorMessage)

        writer.result = .success
        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertNil(store.storageErrorMessage)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
        XCTAssertEqual(store.items.first?.text, "RECOVER ME")
    }

    func testReCopyPlainTextClearsStaleRichTextData() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!
        storage.save([
            ClipboardItem(text: "Hello", rtfData: rtfData, htmlData: htmlData)
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Hello", forType: .string))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.text, "Hello")
        XCTAssertNil(item.rtfData)
        XCTAssertNil(item.htmlData)
        XCTAssertFalse(item.hasRichText)
    }
}

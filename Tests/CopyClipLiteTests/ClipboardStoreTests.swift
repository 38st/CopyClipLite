import AppKit
import Foundation
import XCTest
@testable import CopyClipLite

private actor DelayedImageProcessor: ClipboardImageProcessing {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return ClipboardImagePayload(
            data: candidate.data,
            thumbnailData: candidate.data,
            width: 1,
            height: 1,
            contentHash: ClipboardImageProcessor.contentHash(for: candidate.data)
        )
    }
}

@MainActor
final class ClipboardStoreTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDownWithError() throws {
        for suiteName in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaultsSuites.removeAll()

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()

        try super.tearDownWithError()
    }

    func testInitializationPrunesExpiredUnpinnedItemsButKeepsPinnedItems() throws {
        let now = Date()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "expired", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            ClipboardItem(text: "pinned", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), isPinned: true),
            ClipboardItem(text: "recent", lastCopiedAt: now.addingTimeInterval(-60))
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
            ClipboardItem(text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(clips + [
            ClipboardItem(text: "pinned", lastCopiedAt: now.addingTimeInterval(-1_000), isPinned: true)
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
            ClipboardItem(text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(clips + [
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

    func testPollingCapturesImagePasteboardData() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 3, height: 4)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let image = try XCTUnwrap(item.image)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertNotNil(image.data)
        XCTAssertNotNil(image.thumbnailData)
        XCTAssertNotNil(image.contentHash)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 4)
        XCTAssertEqual(item.previewText, "Image")
        XCTAssertEqual(store.visibleItems(matching: "image").map(\.id), [item.id])
    }

    func testFlushExternalizesLiveImagePayloadWithoutBreakingCopy() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 3, height: 3)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        XCTAssertNotNil(store.items.first?.image?.data)

        XCTAssertTrue(store.flushPendingPersist())

        let externalizedItem = try XCTUnwrap(store.items.first)
        XCTAssertNil(externalizedItem.image?.data)
        XCTAssertNotNil(externalizedItem.image?.fileName)
        XCTAssertTrue(store.copy(externalizedItem))
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    func testClearInvalidatesPendingImageCapture() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            imageProcessor: DelayedImageProcessor(delayNanoseconds: 200_000_000)
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        store.pollPasteboardForChanges()
        store.clearHistory()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(store.items.isEmpty)
    }

    func testDuplicateImageRefreshesAssociatedText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("caption A", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("caption B", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.text, "caption B")
        XCTAssertEqual(item.previewText, "Image · caption B")
        XCTAssertEqual(store.visibleItems(matching: "caption B").map(\.id), [item.id])
    }

    func testDeletingAnotherClipKeepsLiveCapturedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 4, height: 4)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageID = try XCTUnwrap(store.items.first?.id)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("delete me", forType: .string))
        store.pollPasteboardForChanges()
        let textItem = try XCTUnwrap(store.items.first(where: { $0.text == "delete me" }))

        store.delete(textItem)

        let reloadedImage = try XCTUnwrap(storage.load().first(where: { $0.id == imageID }))
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))
    }

    func testClearKeepingPinnedKeepsLiveCapturedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 5, height: 5)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageItem = try XCTUnwrap(store.items.first)
        store.togglePin(imageItem)

        store.clearHistory()

        let reloadedImage = try XCTUnwrap(storage.load().first)
        XCTAssertTrue(reloadedImage.isPinned)
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))
    }

    func testCopyImageItemWritesImagePasteboardTypes() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let pngData = try makePNGData(width: 2, height: 3)
        storage.save([
            ClipboardItem(image: ClipboardImagePayload(data: pngData, width: 2, height: 3))
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertNil(item.image?.data)

        store.copy(item)

        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testMissingImageDoesNotClearExistingClipboardOrReportCopySuccess() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(image: ClipboardImagePayload(data: try makePNGData(width: 2, height: 2), width: 2, height: 2))
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let item = try XCTUnwrap(store.items.first)
        for fileName in [item.image?.fileName, item.image?.thumbnailFileName].compactMap({ $0 }) {
            try FileManager.default.removeItem(at: storage.imageDirectoryURL.appendingPathComponent(fileName))
        }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertFalse(store.copy(item))

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertEqual(store.items.first?.copyCount, 1)
        XCTAssertNotNil(store.storageErrorMessage)
    }

    func testImagePasteboardWithAssociatedTextKeepsText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 4, height: 5)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("chart caption", forType: .string))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.text, "chart caption")
        XCTAssertEqual(item.previewText, "Image · chart caption")
        XCTAssertEqual(store.visibleItems(matching: "caption").map(\.id), [item.id])

        store.copy(item)

        try assertReadableImageData(pasteboard.data(forType: .png))
        XCTAssertEqual(pasteboard.string(forType: .string), "chart caption")
    }

    func testPollingStoresSourceApplicationMetadata() throws {
        let pasteboard = makePasteboard()
        let sourceApplication = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Notes",
            name: "Notes"
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { sourceApplication }
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("note text", forType: .string))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.sourceApplication, sourceApplication)
        XCTAssertEqual(store.visibleItems(matching: "Notes").map(\.id), [item.id])
    }

    func testIgnoredSourceApplicationIsNotCaptured() throws {
        let pasteboard = makePasteboard()
        let sourceApplication = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { sourceApplication }
        )
        store.addIgnoredApplication(sourceApplication)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("private value", forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertTrue(store.items.isEmpty)
    }

    func testVisibleItemsCanFilterByContentKindAndPinnedState() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let image = ClipboardImagePayload(data: Data([0, 1, 2, 3]), width: 12, height: 34)
        storage.save([
            ClipboardItem(text: "plain text"),
            ClipboardItem(text: "pinned text", isPinned: true),
            ClipboardItem(image: image)
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )

        XCTAssertEqual(store.visibleItems(matching: "", filter: .text).map(\.text).sorted(), [
            "pinned text",
            "plain text"
        ])
        XCTAssertEqual(store.visibleItems(matching: "", filter: .images).count, 1)
        XCTAssertEqual(store.visibleItems(matching: "", filter: .pinned).map(\.text), ["pinned text"])
    }

    func testPauseMonitoringPersistsResumeDate() throws {
        let defaults = makeDefaults()
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults
        )

        store.pauseMonitoring(for: .fiveMinutes)

        XCTAssertFalse(store.isMonitoringEnabled)
        let pausedUntil = try XCTUnwrap(store.monitoringPausedUntil)
        XCTAssertGreaterThan(pausedUntil, Date())
        XCTAssertEqual(defaults.object(forKey: "monitoringPausedUntil") as? Date, pausedUntil)

        store.setMonitoringEnabled(true)

        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
        XCTAssertNil(defaults.object(forKey: "monitoringPausedUntil"))
    }

    func testExpiredTimedPauseResumesMonitoringAfterRelaunch() throws {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(Date().addingTimeInterval(-60), forKey: "monitoringPausedUntil")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults
        )

        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
        XCTAssertEqual(defaults.object(forKey: "monitoringEnabled") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "monitoringPausedUntil"))
    }

    func testManualPauseRemainsDisabledAfterRelaunch() throws {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults
        )

        XCTAssertFalse(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
    }

    func testUnpinningAtHistoryLimitTrimsExcessItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<10).map { index in
            ClipboardItem(text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
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

    func testClearUnpinnedOnQuitKeepsPinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")

        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let unpinned = ClipboardItem(text: "unpinned")
        storage.save([pinned, unpinned])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults
        )
        store.clearUnpinnedHistoryOnQuitIfNeeded()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "pinned")
    }

    func testClearUnpinnedOnQuitKeepsLiveCapturedPinnedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        defaults.set(false, forKey: "keepPinnedOnClear")
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: defaults
        )
        let pngData = try makePNGData(width: 6, height: 6)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageItem = try XCTUnwrap(store.items.first)
        store.togglePin(imageItem)

        store.clearUnpinnedHistoryOnQuitIfNeeded()

        let reloadedImage = try XCTUnwrap(storage.load().first)
        XCTAssertTrue(reloadedImage.isPinned)
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))
    }

    func testStaticClearOnQuitAlwaysKeepsPinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        defaults.set(false, forKey: "keepPinnedOnClear")

        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let unpinned = ClipboardItem(text: "unpinned")
        storage.save([pinned, unpinned])

        ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded(storage: storage, defaults: defaults)

        let remaining = storage.load()
        XCTAssertEqual(remaining.map(\.text), ["pinned"])
    }

    func testCopyWithTransformationRecordsTransformedText() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "hello world")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO WORLD")
        let transformedItem = try XCTUnwrap(store.items.first)
        XCTAssertEqual(transformedItem.text, "HELLO WORLD")
        XCTAssertEqual(transformedItem.copyCount, 1)
        XCTAssertEqual(store.lastCopiedID, transformedItem.id)
    }

    func testCopyWithTransformationDeduplicatesExistingItem() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "HELLO WORLD"),
            ClipboardItem(text: "hello world")
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first(where: { $0.text == "hello world" }))

        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertEqual(store.items.filter { $0.text == "HELLO WORLD" }.count, 1)
        let transformedItem = try XCTUnwrap(store.items.first)
        XCTAssertEqual(transformedItem.text, "HELLO WORLD")
        XCTAssertEqual(transformedItem.copyCount, 2)
    }

    func testTextCaptureDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "same content",
                image: ClipboardImagePayload(data: Data([1, 2, 3]), width: 1, height: 1)
            )
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("same content", forType: .string))
        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.filter { $0.contentKind == .text }.count, 1)
        XCTAssertEqual(store.items.filter { $0.contentKind == .image }.count, 1)
    }

    func testTransformationDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "HELLO",
                image: ClipboardImagePayload(data: Data([1, 2, 3]), width: 1, height: 1)
            ),
            ClipboardItem(text: "hello")
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let textItem = try XCTUnwrap(store.items.first(where: { $0.contentKind == .text }))

        store.copyWithTransformation(textItem, transformation: .uppercase)

        XCTAssertEqual(store.items.filter { $0.contentKind == .image }.count, 1)
        XCTAssertEqual(
            store.items.filter { $0.contentKind == .text && $0.text == "HELLO" }.count,
            1
        )
    }

    func testCopyWithTransformationEmptyResultIsIgnored() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "   ")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let initialCount = store.items.count
        let item = try XCTUnwrap(store.items.first)

        store.copyWithTransformation(item, transformation: .stripFormatting)

        XCTAssertEqual(store.items.count, initialCount)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testPollingCapturesRTFAndHTMLData() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )

        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Hello", forType: .string))
        XCTAssertTrue(pasteboard.setData(rtfData, forType: .rtf))
        XCTAssertTrue(pasteboard.setData(htmlData, forType: .html))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.text, "Hello")
        XCTAssertEqual(item.rtfData, rtfData)
        XCTAssertEqual(item.htmlData, htmlData)
        XCTAssertTrue(item.hasRichText)
    }

    func testCopyWritesRTFAndHTMLToPasteboard() throws {
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
        let item = try XCTUnwrap(store.items.first)

        store.copy(item)

        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtfData)
        XCTAssertEqual(pasteboard.data(forType: .html), htmlData)
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

    func testRTFHTMLDataSurvivesStorageRoundTrip() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!
        storage.save([
            ClipboardItem(text: "Hello", rtfData: rtfData, htmlData: htmlData)
        ])

        let loadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(loadedItem.text, "Hello")
        XCTAssertEqual(loadedItem.rtfData, rtfData)
        XCTAssertEqual(loadedItem.htmlData, htmlData)
    }

    func testImportMergesByDefaultPathAndCreatesPrivateBackup() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("import.json")
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([ClipboardItem(text: "imported")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )

        let backupURL = try store.importHistory(from: importURL, strategy: .merge)

        XCTAssertEqual(Set(store.items.map(\.text)), ["existing", "imported"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try permissions(at: backupURL), 0o600)
    }

    func testPendingPersistCannotOverwriteMergedImport() async throws {
        try await assertPendingPersistCannotOverwriteImport(strategy: .merge)
    }

    func testPendingPersistCannotOverwriteReplacedImport() async throws {
        try await assertPendingPersistCannotOverwriteImport(strategy: .replace)
    }

    func testFailedDeletePersistKeepsPreviouslyCommittedImageReadable() throws {
        final class FaultSwitch {
            var failManifestWrite = false
        }

        let faultSwitch = FaultSwitch()
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(
            appDirectory: directory,
            faultInjector: { point in
                if case .manifestWrite = point, faultSwitch.failManifestWrite {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let pngData = try makePNGData(width: 3, height: 3)
        storage.save([
            ClipboardItem(image: ClipboardImagePayload(data: pngData, width: 3, height: 3)),
            ClipboardItem(text: "keep")
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        let imageItem = try XCTUnwrap(store.items.first(where: { $0.isImage }))
        faultSwitch.failManifestWrite = true

        store.delete(imageItem)

        XCTAssertNotNil(store.storageErrorMessage)
        let committedImage = try XCTUnwrap(storage.load().first(where: { $0.isImage }))
        XCTAssertEqual(storage.imageData(for: committedImage), pngData)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CopyClipLiteTests-\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("CopyClipLiteTests-\(UUID().uuidString)"))
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))

        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(
                    NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.9, alpha: 1),
                    atX: x,
                    y: y
                )
            }
        }

        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    private func waitForCapturedItem(in store: ClipboardStore) async throws {
        for _ in 0..<100 where store.items.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.items.isEmpty, "Timed out waiting for background image processing")
    }

    private func waitForCopyCount(_ copyCount: Int, in store: ClipboardStore) async throws {
        for _ in 0..<100 where store.items.first?.copyCount != copyCount {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.items.first?.copyCount, copyCount)
    }

    private func assertReadableImageData(
        _ data: Data?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(data, file: file, line: line)
        XCTAssertNotNil(NSImage(data: data), file: file, line: line)
    }

    private func assertPendingPersistCannotOverwriteImport(
        strategy: ClipboardImportStrategy
    ) async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("import-race.json")
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([ClipboardItem(text: "imported")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let existingItem = try XCTUnwrap(store.items.first)
        store.togglePin(existingItem)

        try store.importHistory(from: importURL, strategy: strategy)
        try await Task.sleep(nanoseconds: 350_000_000)

        let persistedTexts = Set(storage.load().map(\.text))
        switch strategy {
        case .merge:
            XCTAssertEqual(persistedTexts, ["existing", "imported"])
        case .replace:
            XCTAssertEqual(persistedTexts, ["imported"])
        }
        XCTAssertEqual(Set(store.items.map(\.text)), persistedTexts)
    }
}

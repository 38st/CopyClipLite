import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

private actor SequencedImageProcessor: ClipboardImageProcessing {
    private var invocation = 0

    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload {
        invocation += 1
        let currentInvocation = invocation
        try await Task.sleep(
            nanoseconds: currentInvocation == 1 ? 150_000_000 : 5_000_000
        )
        return ClipboardImagePayload(
            data: candidate.data,
            thumbnailData: candidate.data,
            width: 1,
            height: 1,
            contentHash: ClipboardImageProcessor.contentHash(for: candidate.data)
        )
    }
}

private actor RecordingDelayedImageProcessor: ClipboardImageProcessing {
    private let delayNanoseconds: UInt64
    private var startedData: [Data] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload {
        startedData.append(candidate.data)
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return ClipboardImagePayload(
            data: candidate.data,
            thumbnailData: candidate.data,
            width: 1,
            height: 1,
            contentHash: ClipboardImageProcessor.contentHash(for: candidate.data)
        )
    }

    func started() -> [Data] {
        startedData
    }
}

private actor ExternalizingStressImageProcessor: ClipboardImageProcessing {
    let payloadByteCount: Int

    init(payloadByteCount: Int) {
        self.payloadByteCount = payloadByteCount
    }

    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload {
        let marker = candidate.data.first ?? 0
        let data = Data(repeating: marker, count: payloadByteCount)
        return ClipboardImagePayload(
            data: data,
            thumbnailData: Data(repeating: marker, count: 1_024),
            width: 1,
            height: 1,
            contentHash: ClipboardImageProcessor.contentHash(for: data)
        )
    }
}

private final class ManualClipboardClock: @unchecked Sendable {
    private struct Sleeper {
        let wakeDate: Date
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentDate: Date
    private var sleepers: [Sleeper] = []

    init(now: Date) {
        currentDate = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            lock.lock()
            sleepers.append(
                Sleeper(
                    wakeDate: currentDate.addingTimeInterval(
                        TimeInterval(nanoseconds) / 1_000_000_000
                    ),
                    continuation: continuation
                )
            )
            lock.unlock()
        }
        try Task.checkCancellation()
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(interval)
        let ready = sleepers.filter { $0.wakeDate <= currentDate }
        sleepers.removeAll { $0.wakeDate <= currentDate }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }
}

private final class StubPasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
    var result: ClipboardPasteboardWriteResult
    private(set) var requests: [ClipboardPasteboardWriteRequest] = []

    init(result: ClipboardPasteboardWriteResult) {
        self.result = result
    }

    func write(_ request: ClipboardPasteboardWriteRequest) -> ClipboardPasteboardWriteResult {
        requests.append(request)
        return result
    }
}

private final class SelectiveFailurePasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
    let failingTypes: Set<String>
    private(set) var requests: [ClipboardPasteboardWriteRequest] = []

    init(failingTypes: Set<String>) {
        self.failingTypes = failingTypes
    }

    func write(_ request: ClipboardPasteboardWriteRequest) -> ClipboardPasteboardWriteResult {
        requests.append(request)
        if request.required.contains(where: { failingTypes.contains($0.type) }) {
            return .failure
        }

        let failedOptionalTypes = request.optional
            .map(\.type)
            .filter(failingTypes.contains)
        return failedOptionalTypes.isEmpty
            ? .success
            : .degraded(optionalTypes: failedOptionalTypes)
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

    func testPersistedHistoryLimitIsClampedBeforeStartupPruning() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save((0..<12).map { ClipboardItem(text: "clip-\($0)") })
        let defaults = makeDefaults()
        defaults.set(0, forKey: "historyLimit")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults
        )

        XCTAssertEqual(store.historyLimit, 10)
        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(defaults.integer(forKey: "historyLimit"), 10)
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

    func testLiveImageStressExternalizesPayloadsAndBoundsResidentMemory() async throws {
        let payloadByteCount = 2 * 1024 * 1024
        let captureCount = 48
        let maximumResidentGrowth = UInt64(80 * 1024 * 1024)
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: ExternalizingStressImageProcessor(
                payloadByteCount: payloadByteCount
            ),
            pasteboardWriter: writer
        )
        store.setHistoryLimit(200)

        ProcessMemoryMetrics.relieveAllocatorPressure()
        let baselineResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()

        for marker in 1...captureCount {
            pasteboard.clearContents()
            XCTAssertTrue(
                pasteboard.setData(
                    Data([UInt8(marker)]),
                    forType: .png
                )
            )
            store.pollPasteboardForChanges()
            for _ in 0..<500 where store.items.count < marker {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(store.items.count, marker)
            XCTAssertTrue(store.flushPendingPersist())
            XCTAssertEqual(
                store.items.reduce(0) {
                    $0 + ($1.image?.data?.count ?? 0)
                        + ($1.image?.thumbnailData?.count ?? 0)
                },
                0
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        ProcessMemoryMetrics.relieveAllocatorPressure()
        let finalResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()
        let residentGrowth = ProcessMemoryMetrics.positiveGrowth(
            from: baselineResidentBytes,
            to: finalResidentBytes
        )

        XCTAssertEqual(store.items.count, captureCount)
        XCTAssertLessThan(
            residentGrowth,
            maximumResidentGrowth,
            "Committed live images retained \(residentGrowth) bytes of resident memory"
        )
        let first = try XCTUnwrap(store.items.first)
        let last = try XCTUnwrap(store.items.last)
        XCTAssertTrue(store.copy(first))
        XCTAssertTrue(store.copy(last))
        XCTAssertEqual(writer.requests.count, 2)
        XCTAssertEqual(
            writer.requests.map { request in
                request.required.reduce(0) {
                    guard case let .data(data) = $1.value else { return $0 }
                    return $0 + data.count
                }
            },
            [payloadByteCount, payloadByteCount]
        )
    }

    func testAsyncThumbnailLookupRepairsSidecarDeletedAfterInitialization() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 8, height: 8)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: imageData,
                    width: 8,
                    height: 8
                )
            )
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let item = try XCTUnwrap(store.items.first)
        let oldThumbnailName = try XCTUnwrap(item.image?.thumbnailFileName)
        try FileManager.default.removeItem(
            at: storage.imageDirectoryURL.appendingPathComponent(oldThumbnailName)
        )

        XCTAssertNil(store.cachedThumbnailData(for: item))
        for _ in 0..<100 where store.cachedThumbnailData(for: item) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let repairedData = try XCTUnwrap(store.cachedThumbnailData(for: item))
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedData))
        XCTAssertEqual(store.cachedThumbnailData(for: item), repairedData)
        let repairedName = try XCTUnwrap(store.items.first?.image?.thumbnailFileName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.imageDirectoryURL
                    .appendingPathComponent(repairedName)
                    .path
            )
        )
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

    func testRapidImageCapturesKeepOneInFlightAndLatestSevenQueuedInOrder() async throws {
        let pasteboard = makePasteboard()
        let processor = RecordingDelayedImageProcessor(delayNanoseconds: 40_000_000)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: processor
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([0]), forType: .png))
        XCTAssertTrue(pasteboard.setString("capture-0", forType: .string))
        store.pollPasteboardForChanges()
        for _ in 0..<100 where await processor.started().isEmpty {
            await Task.yield()
        }
        let initiallyStarted = await processor.started()
        XCTAssertEqual(initiallyStarted, [Data([0])])

        for value in 1..<20 {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setData(Data([UInt8(value)]), forType: .png))
            XCTAssertTrue(pasteboard.setString("capture-\(value)", forType: .string))
            store.pollPasteboardForChanges()
        }

        for _ in 0..<200 where store.items.count < 8 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.items.count, 8)
        XCTAssertEqual(
            Set(store.items.map(\.text)),
            Set(["capture-0"] + (13..<20).map { "capture-\($0)" })
        )
        let allStarted = await processor.started()
        XCTAssertEqual(allStarted, [Data([0])] + (13..<20).map { Data([UInt8($0)]) })
    }

    func testQuitCleanupCancelsPendingImageCapture() async throws {
        let pasteboard = makePasteboard()
        let processor = RecordingDelayedImageProcessor(delayNanoseconds: 200_000_000)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: processor
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1]), forType: .png))
        store.pollPasteboardForChanges()
        for _ in 0..<100 where await processor.started().isEmpty {
            await Task.yield()
        }

        store.clearUnpinnedHistoryOnQuitIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)

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

    func testDuplicateImageRefreshesTextToEmptyAndBackToText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        pasteboard.setString("first", forType: .string)
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)
        XCTAssertEqual(store.items.first?.text, "")

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        pasteboard.setString("restored", forType: .string)
        store.pollPasteboardForChanges()
        try await waitForCopyCount(3, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "restored")
        XCTAssertEqual(store.items.first?.previewText, "Image · restored")
    }

    func testOlderImageCompletionCannotOverwriteNewestAssociatedText() async throws {
        let pasteboard = makePasteboard()
        let imageData = try makePNGData(width: 2, height: 2)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: SequencedImageProcessor()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        XCTAssertTrue(pasteboard.setString("older caption", forType: .string))
        store.pollPasteboardForChanges()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        XCTAssertTrue(pasteboard.setString("newest caption", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertEqual(store.items.first?.text, "newest caption")
    }

    func testLegacyRawPNGRecopyDeduplicatesAgainstCanonicalCapture() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rawPNG = try makePNGData(width: 3, height: 3)
        let imageFileName = "legacy-raw.png"
        try rawPNG.write(
            to: storage.imageDirectoryURL.appendingPathComponent(imageFileName)
        )
        let legacyJSON = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"legacy",
          "contentKind":"image",
          "image":{
            "fileName":"\(imageFileName)",
            "width":3,
            "height":3,
            "byteCount":\(rawPNG.count)
          },
          "copyCount":1
        }]
        """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(rawPNG, forType: .png))
        XCTAssertTrue(pasteboard.setString("latest", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "latest")
        XCTAssertEqual(
            store.items.first?.image?.contentHash,
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: rawPNG, isPNG: true)
            ).contentHash
        )
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

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(
            reloadedStore.items.first(where: { $0.id == imageID })
        )
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
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

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(reloadedStore.items.first)
        XCTAssertTrue(reloadedStoreImage.isPinned)
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
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
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testImageCopyRequestsPNGWithoutEagerTIFFGeneration() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 3),
                    width: 2,
                    height: 3
                )
            )
        ])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))

        let request = try XCTUnwrap(writer.requests.first)
        XCTAssertEqual(request.required.map(\.type), [NSPasteboard.PasteboardType.png.rawValue])
        XCTAssertFalse(
            (request.required + request.optional)
                .contains { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        )
    }

    func testMaximumSupportedValidImageCopyDoesNotDecodeOrBlockMainActor() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let side = 4_096
        XCTAssertEqual(side * side, ClipboardImageProcessor.maximumPixelCount)
        let maximumDimensionPNG = try makeSolidPNGData(width: side, height: side)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: maximumDimensionPNG,
                    width: side,
                    height: side
                )
            )
        ])
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)
        let start = ContinuousClock.now

        XCTAssertTrue(store.copy(item))

        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(pasteboard.data(forType: .png), maximumDimensionPNG)
    }

    func testNearEncodedLimitValidImageCopyMeetsLatencyAndResidentBudgets() throws {
        let maximumCopyLatency = Duration.seconds(1)
        let maximumResidentGrowth = UInt64(
            ClipboardImageProcessor.maximumEncodedBytes + 32 * 1024 * 1024
        )
        let image = try NearLimitImageFixture.canonicalPNG()
        let imageData = try XCTUnwrap(image.data)
        XCTAssertGreaterThanOrEqual(
            imageData.count,
            ClipboardImageProcessor.maximumEncodedBytes * 8 / 10
        )
        XCTAssertLessThanOrEqual(
            imageData.count,
            ClipboardImageProcessor.maximumEncodedBytes
        )
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(imageData))

        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(image: image)])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)

        ProcessMemoryMetrics.relieveAllocatorPressure()
        let baselineResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()
        let sampler = ProcessResidentPeakSampler(
            baselineResidentBytes: baselineResidentBytes
        )
        sampler.start()
        let start = ContinuousClock.now

        XCTAssertTrue(store.copy(item))

        let elapsed = start.duration(to: .now)
        let peakResidentBytes = sampler.stop()
        let residentGrowth = ProcessMemoryMetrics.positiveGrowth(
            from: baselineResidentBytes,
            to: peakResidentBytes
        )
        XCTAssertLessThan(elapsed, maximumCopyLatency)
        XCTAssertLessThan(
            residentGrowth,
            maximumResidentGrowth,
            "Copy grew resident memory by \(residentGrowth) bytes"
        )
        let request = try XCTUnwrap(writer.requests.first)
        XCTAssertEqual(request.required.map(\.type), [NSPasteboard.PasteboardType.png.rawValue])
        XCTAssertEqual(request.required.first?.value, .data(imageData))
        XCTAssertFalse(
            (request.required + request.optional)
                .contains { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        )
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

    func testOptionalPasteboardWriteFailureIsReportedAsDegradedCopy() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "hello",
                rtfData: Data("rtf".utf8),
                htmlData: Data("html".utf8)
            )
        ])
        let writer = StubPasteboardWriter(
            result: .degraded(optionalTypes: [NSPasteboard.PasteboardType.rtf.rawValue])
        )
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertTrue(store.pasteboardWriteWarning?.contains("optional formats") == true)
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

    func testOptionalPasteboardRepresentationFailureMatrixReportsDegradation() throws {
        for failedType in [
            NSPasteboard.PasteboardType.rtf,
            NSPasteboard.PasteboardType.html
        ] {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([
                ClipboardItem(
                    text: "rich",
                    rtfData: Data("rtf".utf8),
                    htmlData: Data("html".utf8)
                )
            ])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [failedType.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeDefaults(),
                pasteboardWriter: writer
            )

            XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
            XCTAssertEqual(store.items.first?.copyCount, 2)
            XCTAssertEqual(
                writer.requests.first?.optional.map(\.type),
                [
                    NSPasteboard.PasteboardType.rtf.rawValue,
                    NSPasteboard.PasteboardType.html.rawValue
                ]
            )
            XCTAssertTrue(
                store.pasteboardWriteWarning?.contains(failedType.rawValue) == true
            )
            XCTAssertNil(store.storageErrorMessage)
        }

        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "associated text",
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                )
            )
        ])
        let writer = SelectiveFailurePasteboardWriter(
            failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
        )
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertEqual(
            writer.requests.first?.required.map(\.type),
            [NSPasteboard.PasteboardType.png.rawValue]
        )
        XCTAssertEqual(
            writer.requests.first?.optional.map(\.type),
            [NSPasteboard.PasteboardType.string.rawValue]
        )
        XCTAssertTrue(
            store.pasteboardWriteWarning?
                .contains(NSPasteboard.PasteboardType.string.rawValue) == true
        )
        XCTAssertNil(store.storageErrorMessage)
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
        let base = Date(timeIntervalSinceReferenceDate: 20_000)
        let clock = ManualClipboardClock(now: base)
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(base.addingTimeInterval(-60), forKey: "monitoringPausedUntil")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
        XCTAssertEqual(defaults.object(forKey: "monitoringEnabled") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "monitoringPausedUntil"))
    }

    func testFutureTimedPauseRelaunchResumesExactlyAtInjectedDeadline() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let clock = ManualClipboardClock(now: base)
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(base.addingTimeInterval(60), forKey: "monitoringPausedUntil")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertFalse(store.isMonitoringEnabled)
        for _ in 0..<100 where clock.waitingCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(clock.waitingCount, 1)

        clock.advance(by: 59)
        await Task.yield()
        XCTAssertFalse(store.isMonitoringEnabled)

        clock.advance(by: 1)
        for _ in 0..<100 where !store.isMonitoringEnabled {
            await Task.yield()
        }
        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
    }

    func testManualPauseRemainsDisabledAfterRelaunch() throws {
        let clock = ManualClipboardClock(
            now: Date(timeIntervalSinceReferenceDate: 30_000)
        )
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertFalse(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
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

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(reloadedStore.items.first)
        XCTAssertTrue(reloadedStoreImage.isPinned)
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
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

    func testTextCaptureDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                text: "same content",
                image: ClipboardImagePayload(data: imageData, width: 2, height: 2)
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

        let imageItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .image })
        )
        let textItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .text })
        )
        XCTAssertTrue(store.copy(imageItem))
        try assertReadableImageData(pasteboard.data(forType: .png))
        XCTAssertTrue(store.copy(textItem))
        XCTAssertEqual(pasteboard.string(forType: .string), "same content")
    }

    func testTransformationDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                text: "HELLO",
                image: ClipboardImagePayload(data: imageData, width: 2, height: 2)
            ),
            ClipboardItem(text: "hello")
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let textItem = try XCTUnwrap(store.items.first(where: { $0.contentKind == .text }))
        let originalImageItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .image })
        )

        store.copyWithTransformation(textItem, transformation: .uppercase)

        XCTAssertEqual(store.items.filter { $0.contentKind == .image }.count, 1)
        XCTAssertEqual(
            store.items.first(where: { $0.contentKind == .image }),
            originalImageItem
        )
        XCTAssertEqual(
            store.items.filter { $0.contentKind == .text && $0.text == "HELLO" }.count,
            1
        )
        XCTAssertTrue(store.copy(originalImageItem))
        try assertReadableImageData(pasteboard.data(forType: .png))
    }

    func testStripFormattingCopiesWhitespaceOnlyLegacyTextExactly() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "   ")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        store.copyWithTransformation(item, transformation: .stripFormatting)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "   ")
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testStripFormattingPreservesExactWhitespaceAndUnicode() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let exactText = "  let café = \"☕️\"\n\n\tprint(café)  "
        storage.save([ClipboardItem(text: exactText, rtfData: Data("rtf".utf8))])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )

        store.copyWithTransformation(
            try XCTUnwrap(store.items.first),
            transformation: .stripFormatting
        )

        XCTAssertEqual(pasteboard.string(forType: .string), exactText)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertNil(pasteboard.data(forType: .html))
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

    func testPollingExtractsPlainTextFromRTFWithoutStringFlavor() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let attributed = NSAttributedString(string: "RTF only")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(rtf, forType: .rtf))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "RTF only")
        XCTAssertEqual(store.items.first?.rtfData, rtf)
    }

    func testOversizedTextShowsWarningInsteadOfDisappearingSilently() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(String(repeating: "a", count: 20_001), forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.captureWarning?.contains("20,000") == true)
    }

    func testMaximumLengthTextCapturesAtBoundary() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let text = String(repeating: "a", count: 20_000)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text.count, 20_000)
        XCTAssertNil(store.captureWarning)
    }

    func testSuccessfulCaptureClearsOnlyItsCaptureIssue() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let item = ClipboardItem(text: "paste issue probe")
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString(
                String(repeating: "x", count: 20_001),
                forType: .string
            )
        )
        store.pollPasteboardForChanges()
        XCTAssertNotNil(store.captureWarning)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("valid recovery", forType: .string))
        store.pollPasteboardForChanges()

        XCTAssertNil(store.captureWarning)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
        XCTAssertEqual(store.items.first?.text, "valid recovery")
    }

    func testSuccessfulImageCaptureClearsOnlyItsCaptureIssue() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let item = ClipboardItem(text: "paste issue probe")
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        store.pollPasteboardForChanges()
        for _ in 0..<100 where store.captureWarning == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.captureWarning)

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                try makePNGData(width: 2, height: 2),
                forType: .png
            )
        )
        store.pollPasteboardForChanges()
        for _ in 0..<100 where store.items.first?.isImage != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(store.items.first?.isImage == true)
        XCTAssertNil(store.captureWarning)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
    }

    func testOversizedRichTextIsDroppedWithWarningWhilePlainTextSurvives() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        pasteboard.clearContents()
        pasteboard.setString("plain survives", forType: .string)
        pasteboard.setData(
            Data(repeating: 0x41, count: ClipboardStorage.maximumImportedRichTextBytes + 1),
            forType: .rtf
        )

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "plain survives")
        XCTAssertNil(store.items.first?.rtfData)
        XCTAssertTrue(store.captureWarning?.contains("oversized RTF") == true)
    }

    func testRTFAndHTMLBoundaryPayloadsCaptureExportAndReimport() throws {
        let directory = try makeTemporaryDirectory()
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let boundary = ClipboardStorage.maximumImportedRichTextBytes
        let rtfData = Data(repeating: 0x52, count: boundary)
        let htmlData = Data(repeating: 0x48, count: boundary)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("boundary rich text", forType: .string))
        XCTAssertTrue(pasteboard.setData(rtfData, forType: .rtf))
        XCTAssertTrue(pasteboard.setData(htmlData, forType: .html))

        store.pollPasteboardForChanges()

        let captured = try XCTUnwrap(store.items.first)
        XCTAssertEqual(captured.rtfData?.count, boundary)
        XCTAssertEqual(captured.htmlData?.count, boundary)
        XCTAssertNil(store.captureWarning)

        let exportURL = directory.appendingPathComponent("rich-boundary.json")
        try storage.export(store.items, to: exportURL)
        let imported = try storage.importItems(from: exportURL)
        XCTAssertEqual(imported.first?.rtfData, rtfData)
        XCTAssertEqual(imported.first?.htmlData, htmlData)
    }

    func testOversizedHTMLIsDroppedWithSpecificWarning() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("plain survives", forType: .string))
        XCTAssertTrue(
            pasteboard.setData(
                Data(
                    repeating: 0x48,
                    count: ClipboardStorage.maximumImportedRichTextBytes + 1
                ),
                forType: .html
            )
        )

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "plain survives")
        XCTAssertNil(store.items.first?.htmlData)
        XCTAssertTrue(store.captureWarning?.contains("oversized HTML") == true)
    }

    func testInvalidImageFallsBackToCapturedTextSnapshot() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        XCTAssertTrue(pasteboard.setString("preserve me", forType: .string))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.contentKind, .text)
        XCTAssertEqual(store.items.first?.text, "preserve me")
        XCTAssertNotNil(store.captureWarning)
    }

    func testOversizedImageFallsBackToTheFrozenTextSnapshot() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                Data(
                    repeating: 0xFF,
                    count: ClipboardImageProcessor.maximumInputBytes + 1
                ),
                forType: .png
            )
        )
        XCTAssertTrue(pasteboard.setString("preserve oversized fallback", forType: .string))

        store.pollPasteboardForChanges()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("later pasteboard value", forType: .string))
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.contentKind, .text)
        XCTAssertEqual(store.items.first?.text, "preserve oversized fallback")
        XCTAssertEqual(
            store.captureWarning,
            ClipboardImageProcessingError.encodedDataTooLarge.localizedDescription
        )
    }

    func testPollingCapturesJPEGThroughCanonicalImagePipeline() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: makePNGData(width: 3, height: 2)))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                jpeg,
                forType: NSPasteboard.PasteboardType("public.jpeg")
            )
        )

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.contentKind, .image)
        XCTAssertEqual(store.items.first?.image?.width, 3)
        XCTAssertEqual(store.items.first?.image?.height, 2)
    }

    func testPollingCapturesTIFFThroughCanonicalImagePipeline() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: makePNGData(width: 4, height: 3)))
        let tiffData = try XCTUnwrap(bitmap.tiffRepresentation)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(tiffData, forType: .tiff))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let data = try XCTUnwrap(item.image?.data ?? storage.imageData(for: item))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(item.image?.width, 4)
        XCTAssertEqual(item.image?.height, 3)
    }

    func testPollingCapturesHEICWhenPlatformEncoderIsAvailable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(makePNGData(width: 4, height: 3) as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw XCTSkip("The current runner does not provide a HEIC encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("The current runner could not encode the HEIC fixture")
        }
        let heicData = encodedData as Data
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                heicData,
                forType: NSPasteboard.PasteboardType(UTType.heic.identifier)
            )
        )

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let data = try XCTUnwrap(item.image?.data ?? storage.imageData(for: item))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testPNGHasPriorityOverTIFFWhenBothRepresentationsExist() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)
        let otherBitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 5,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let tiffData = try XCTUnwrap(otherBitmap.tiffRepresentation)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(tiffData, forType: .tiff))
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.image?.width, 2)
        XCTAssertEqual(store.items.first?.image?.height, 2)
    }

    func testPollingExtractsPlainTextFromHTMLWithoutStringFlavor() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let html = Data("<p>HTML <strong>only</strong></p>".utf8)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(html, forType: .html))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "HTML only\n")
        XCTAssertEqual(store.items.first?.htmlData, html)
    }

    func testPollingCapturesFinderCopiedLocalImageFile() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let imageDirectory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        let imageURL = imageDirectory.appendingPathComponent("finder-image.png")
        try makePNGData(width: 5, height: 4).write(to: imageURL)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.contentKind, .image)
        XCTAssertEqual(store.items.first?.image?.width, 5)
        XCTAssertEqual(store.items.first?.image?.height, 4)
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

    func testTextDragProviderOffersPlainAndRichRepresentationsWithoutMutation() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = Data(#"{\rtf1\ansi drag me}"#.utf8)
        let htmlData = Data("<strong>drag me</strong>".utf8)
        storage.save([
            ClipboardItem(text: "drag me", rtfData: rtfData, htmlData: htmlData)
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        let provider = store.dragItemProvider(for: item)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.html.identifier))
        let loadedRTF: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        let loadedHTML: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertEqual(loadedRTF, rtfData)
        XCTAssertEqual(loadedHTML, htmlData)
        XCTAssertEqual(store.items.first?.copyCount, 1)
    }

    func testImageDragProviderOffersCanonicalPNGWithoutMutation() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let pngData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(data: pngData, width: 2, height: 2)
            )
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)
        let provider = store.dragItemProvider(for: item)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let loadedData: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }

        XCTAssertEqual(loadedData, pngData)
        let promisedFileData: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) {
                url,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    do {
                        continuation.resume(returning: try Data(contentsOf: url))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertEqual(promisedFileData, pngData)
        let promisedFileURL: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertTrue(promisedFileURL.isFileURL)
        XCTAssertEqual(promisedFileURL.pathExtension.lowercased(), "png")
        XCTAssertEqual(try Data(contentsOf: promisedFileURL), pngData)
        XCTAssertEqual(store.items.first?.copyCount, 1)
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

    func testImportMergesByCanonicalPlanAndCreatesPrivateBackup() async throws {
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

        let artifact = try await store.prepareImport(from: importURL)
        let plan = store.importPlan(for: artifact)
        let commit = try await store.importHistory(plan: plan, strategy: .merge)

        XCTAssertEqual(Set(store.items.map(\.text)), ["existing", "imported"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: commit.backupURL.path))
        XCTAssertEqual(try permissions(at: commit.backupURL), 0o600)
    }

    func testAsyncImportAppliesExactPreviewedArtifactWhenSourceChanges() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("import.json")
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([ClipboardItem(text: "previewed")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )

        let artifact = try await store.prepareImport(from: importURL)
        sourceStorage.save([ClipboardItem(text: "changed after preview")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let plan = store.importPlan(for: artifact)
        let projection = plan.projection(for: .merge)
        let commit = try await store.importHistory(plan: plan, strategy: .merge)

        XCTAssertEqual(projection.finalCount, 2)
        XCTAssertEqual(commit.items.count, projection.finalCount)
        XCTAssertEqual(Set(store.items.map(\.text)), ["existing", "previewed"])
        XCTAssertFalse(store.items.contains { $0.text == "changed after preview" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: commit.backupURL.path))
        XCTAssertEqual(storage.load(), commit.items)
    }

    func testAsyncMergeImportedImageRemainsCopyableAfterRelaunch() async throws {
        try await assertAsyncImportedImageRemainsCopyableAfterRelaunch(
            strategy: .merge
        )
    }

    func testAsyncReplaceImportedImageRemainsCopyableAfterRelaunch() async throws {
        try await assertAsyncImportedImageRemainsCopyableAfterRelaunch(
            strategy: .replace
        )
    }

    func testNearLimitImportPreparationKeepsMainActorResponsive() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("near-limit.json")
        let maximumRichText = Data(
            repeating: 0x52,
            count: ClipboardStorage.maximumImportedRichTextBytes
        )
        let maximumHTML = Data(
            repeating: 0x48,
            count: ClipboardStorage.maximumImportedRichTextBytes
        )
        sourceStorage.save((0..<3).map { index in
            ClipboardItem(
                text: "near limit \(index)",
                rtfData: maximumRichText,
                htmlData: maximumHTML
            )
        })
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let encodedSize = try XCTUnwrap(
            importURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThan(encodedSize, 75 * 1024 * 1024)
        XCTAssertLessThan(encodedSize, ClipboardStorage.maximumImportBytes)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: directory.appendingPathComponent("Store")),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )

        let startedAt = ContinuousClock.now
        let preparation = Task {
            try await store.prepareImport(from: importURL)
        }
        for _ in 0..<100 where !store.isTransferBusy {
            await Task.yield()
        }

        var mainActorHeartbeats = 0
        var maximumHeartbeatGap = Duration.zero
        var previousHeartbeat = ContinuousClock.now
        while store.isTransferBusy {
            try await Task.sleep(nanoseconds: 10_000_000)
            let heartbeat = ContinuousClock.now
            maximumHeartbeatGap = max(
                maximumHeartbeatGap,
                previousHeartbeat.duration(to: heartbeat)
            )
            previousHeartbeat = heartbeat
            mainActorHeartbeats += 1
        }
        let artifact = try await preparation.value
        let elapsed = startedAt.duration(to: .now)

        // The transfer may finish in under 100 ms on faster runners. One
        // heartbeat proves the measurement loop ran; the maximum-gap assertion
        // below is the actual responsiveness guarantee.
        XCTAssertGreaterThan(mainActorHeartbeats, 0)
        XCTAssertLessThan(maximumHeartbeatGap, .milliseconds(250))
        XCTAssertLessThan(elapsed, .seconds(8))
        XCTAssertEqual(artifact.preview.itemCount, 3)
        XCTAssertTrue(
            artifact.items.allSatisfy {
                $0.rtfData?.count == ClipboardStorage.maximumImportedRichTextBytes
                    && $0.htmlData?.count == ClipboardStorage.maximumImportedRichTextBytes
            }
        )
    }

    func testImportProjectionDisclosesDeduplicationExpirationAndLimitDrops() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("projection.json")
        let now = Date()
        storage.save([
            ClipboardItem(text: "duplicate", createdAt: now, lastCopiedAt: now)
        ])
        var imported = [
            ClipboardItem(text: "duplicate", createdAt: now, lastCopiedAt: now),
            ClipboardItem(
                text: "expired",
                createdAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
                lastCopiedAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
            )
        ]
        imported.append(contentsOf: (0..<12).map {
            let timestamp = now.addingTimeInterval(TimeInterval(-$0))
            return ClipboardItem(
                text: "new-\($0)",
                createdAt: timestamp,
                lastCopiedAt: timestamp
            )
        })
        sourceStorage.save(imported)
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        store.setHistoryLimit(10)

        let artifact = try await store.prepareImport(from: importURL)
        let projection = store.importProjection(for: artifact, strategy: .merge, now: now)

        XCTAssertEqual(projection.deduplicatedCount, 1)
        XCTAssertEqual(projection.expiredCount, 1)
        XCTAssertGreaterThan(projection.overLimitCount, 0)
        XCTAssertEqual(projection.finalCount, 10)
    }

    func testCancellingAsyncImportBeforeCommitLeavesHistoryUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("cancel.json")
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([ClipboardItem(text: "replacement")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        let artifact = try await store.prepareImport(from: importURL)

        let importTask = Task {
            try await store.importHistory(artifact: artifact, strategy: .replace)
        }
        importTask.cancel()

        do {
            _ = try await importTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(store.items.map(\.text), ["existing"])
            XCTAssertEqual(storage.load().map(\.text), ["existing"])
        }
    }

    func testImportPlanExpiresWhenCurrentHistoryChanges() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("stale-plan.json")
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([ClipboardItem(text: "imported")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let artifact = try await store.prepareImport(from: importURL)
        let plan = store.importPlan(for: artifact)
        let existing = try XCTUnwrap(store.items.first)
        store.togglePin(existing)

        do {
            _ = try await store.importHistory(plan: plan, strategy: .merge)
            XCTFail("Expected the stale import plan to be rejected")
        } catch let error as ClipboardStorageError {
            XCTAssertEqual(error, .importPlanExpired)
        }
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

    private func makePasteControllerWithPermissionError(
        item: ClipboardItem,
        store: ClipboardStore
    ) -> PasteTargetController {
        let controller = PasteTargetController(
            runtime: PasteTargetRuntime(
                isAccessibilityGranted: { false },
                requestAccessibilityPermission: {},
                simulatePaste: { false },
                openAccessibilitySettings: {},
                hideApplication: {},
                restoreApplication: {}
            ),
            observeWorkspace: false
        )
        controller.paste(item, using: store)
        return controller
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

    private func makeSolidPNGData(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
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
        final class BlockingFault: @unchecked Sendable {
            let started = DispatchSemaphore(value: 0)
            let allowCompletion = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var shouldBlock = false
            var didBlock = false

            func visit(_ point: ClipboardStorageFaultPoint) {
                guard case .manifestWrite = point else { return }
                lock.lock()
                let block = shouldBlock && !didBlock
                if block {
                    didBlock = true
                }
                lock.unlock()
                guard block else { return }
                started.signal()
                allowCompletion.wait()
            }
        }

        let fault = BlockingFault()
        let storage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Store"),
            faultInjector: fault.visit
        )
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
        fault.shouldBlock = true
        store.togglePin(existingItem)
        XCTAssertEqual(fault.started.wait(timeout: .now() + 2), .success)

        let artifact = try await store.prepareImport(from: importURL)
        let plan = store.importPlan(for: artifact)
        let importTask = Task {
            try await store.importHistory(plan: plan, strategy: strategy)
        }
        for _ in 0..<100 where !store.isTransferBusy {
            await Task.yield()
        }
        XCTAssertTrue(store.isTransferBusy)
        store.delete(existingItem)
        store.setHistoryLimit(10)
        XCTAssertFalse(store.copy(existingItem))
        XCTAssertTrue(store.items.contains { $0.id == existingItem.id })
        XCTAssertEqual(store.historyLimit, 50)
        fault.allowCompletion.signal()
        _ = try await importTask.value
        try await Task.sleep(nanoseconds: 250_000_000)

        let persistedTexts = Set(storage.load().map(\.text))
        switch strategy {
        case .merge:
            XCTAssertEqual(persistedTexts, ["existing", "imported"])
        case .replace:
            XCTAssertEqual(persistedTexts, ["imported"])
        }
        XCTAssertEqual(Set(store.items.map(\.text)), persistedTexts)
    }

    private func assertAsyncImportedImageRemainsCopyableAfterRelaunch(
        strategy: ClipboardImportStrategy
    ) async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Store")
        )
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source")
        )
        let importURL = directory.appendingPathComponent("image-import.json")
        let imageData = try makePNGData(width: 4, height: 3)
        storage.save([ClipboardItem(text: "existing")])
        sourceStorage.save([
            ClipboardItem(
                text: "imported image",
                image: ClipboardImagePayload(
                    data: imageData,
                    width: 4,
                    height: 3
                )
            )
        ])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )

        let artifact = try await store.prepareImport(from: importURL)
        let plan = store.importPlan(for: artifact)
        _ = try await store.importHistory(plan: plan, strategy: strategy)

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let importedImage = try XCTUnwrap(
            reloadedStore.items.first(where: { $0.contentKind == .image })
        )
        XCTAssertTrue(reloadedStore.copy(importedImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
        switch strategy {
        case .merge:
            XCTAssertTrue(reloadedStore.items.contains { $0.text == "existing" })
        case .replace:
            XCTAssertFalse(reloadedStore.items.contains { $0.text == "existing" })
        }
    }
}

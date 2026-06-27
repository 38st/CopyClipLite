import AppKit
import Foundation
import XCTest
@testable import CopyClipLite

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
            ClipboardItem(text: "pinned", lastCopiedAt: now.addingTimeInterval(-1_000), isPinned: true)
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

    func testPollingCapturesImagePasteboardData() throws {
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

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.image?.data, pngData)
        XCTAssertEqual(item.image?.width, 3)
        XCTAssertEqual(item.image?.height, 4)
        XCTAssertEqual(item.previewText, "Image")
        XCTAssertEqual(store.visibleItems(matching: "image").map(\.id), [item.id])
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

        store.copy(item)

        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testClearUnpinnedOnQuitKeepsPinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults
        )
        store.setHistoryLimit(10)

        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let unpinned = ClipboardItem(text: "unpinned")
        store.togglePin(pinned)
        // Directly insert items for the test via copy workaround
        storage.save([pinned, unpinned])
        let reloadedStore = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults
        )
        reloadedStore.clearUnpinnedHistoryOnQuitIfNeeded()

        XCTAssertEqual(reloadedStore.items.count, 1)
        XCTAssertEqual(reloadedStore.items.first?.text, "pinned")
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
}

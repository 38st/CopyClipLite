import Foundation
import XCTest
@testable import CopyClipLite

final class ClipboardStorageTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        try super.tearDownWithError()

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testStorageUsesPrivatePermissions() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)

        storage.save([ClipboardItem(text: "private value")])

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: storage.imageDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(at: storage.fileURL), 0o600)
    }

    func testInvalidHistoryIsBackedUpBeforeReturningEmptyHistory() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        try "not json".write(to: storage.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(storage.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL.path))

        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("clipboard-history.invalid-") && $0.hasSuffix(".json") }

        XCTAssertEqual(backupFiles.count, 1)
        XCTAssertEqual(try permissions(at: directory.appendingPathComponent(backupFiles[0])), 0o600)
    }

    func testLegacyTextOnlyItemsDecodeAsText() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","text":"legacy clip"}]
        """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(loadedItem.contentKind, .text)
        XCTAssertEqual(loadedItem.text, "legacy clip")
        XCTAssertEqual(loadedItem.previewText, "legacy clip")
    }

    func testImageItemsRoundTripThroughStorage() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = Data([0, 1, 2, 3])
        let thumbnailData = Data([9, 8, 7])
        let image = ClipboardImagePayload(
            data: imageData,
            thumbnailData: thumbnailData,
            width: 12,
            height: 34,
            contentHash: "hash"
        )

        storage.save([ClipboardItem(image: image)])

        let loadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(loadedItem.contentKind, .image)
        XCTAssertNil(loadedItem.image?.data)
        XCTAssertEqual(storage.imageData(for: loadedItem), imageData)
        XCTAssertEqual(loadedItem.image?.thumbnailData, thumbnailData)
        XCTAssertNotNil(loadedItem.image?.fileName)
        XCTAssertNotNil(loadedItem.image?.thumbnailFileName)
        XCTAssertEqual(loadedItem.previewText, "Image")

        let historyText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(historyText.contains(imageData.base64EncodedString()))
        XCTAssertFalse(historyText.contains(thumbnailData.base64EncodedString()))
    }

    func testLegacyInlineImageItemsMigrateToImageFilesOnLoad() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = Data([0, 1, 2, 3])
        let thumbnailData = Data([9, 8, 7])
        let legacyJSON = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "contentKind":"image",
          "image":{
            "data":"\(imageData.base64EncodedString())",
            "thumbnailData":"\(thumbnailData.base64EncodedString())",
            "width":12,
            "height":34
          }
        }]
        """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loadedItem = try XCTUnwrap(storage.load().first)

        XCTAssertNil(loadedItem.image?.data)
        XCTAssertEqual(storage.imageData(for: loadedItem), imageData)
        XCTAssertEqual(loadedItem.image?.thumbnailData, thumbnailData)
        XCTAssertEqual(loadedItem.image?.byteCount, imageData.count)

        let migratedHistoryText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(migratedHistoryText.contains(imageData.base64EncodedString()))
        XCTAssertFalse(migratedHistoryText.contains(thumbnailData.base64EncodedString()))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }
}

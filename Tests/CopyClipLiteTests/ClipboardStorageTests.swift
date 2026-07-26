import AppKit
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
            .filter { $0.hasPrefix("Recovery-invalid-") }

        XCTAssertEqual(backupFiles.count, 1)
        let recoveryURL = directory.appendingPathComponent(try XCTUnwrap(backupFiles.first))
        XCTAssertEqual(try permissions(at: recoveryURL), 0o700)
        XCTAssertEqual(
            try permissions(at: recoveryURL.appendingPathComponent("clipboard-history.json")),
            0o600
        )
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
        let imageData = try makePNGData(width: 2, height: 2)
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
        let repairedThumbnail = try XCTUnwrap(storage.thumbnailData(for: loadedItem))
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedThumbnail))
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
        XCTAssertEqual(storage.thumbnailData(for: loadedItem), thumbnailData)
        XCTAssertEqual(loadedItem.image?.byteCount, imageData.count)

        let migratedHistoryText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(migratedHistoryText.contains(imageData.base64EncodedString()))
        XCTAssertFalse(migratedHistoryText.contains(thumbnailData.base64EncodedString()))
    }

    func testExportEmbedsExternalizedImageData() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let exportURL = directory.appendingPathComponent("export.json")
        let imageData = try makePNGData(width: 3, height: 4)
        let thumbnailData = try makePNGData(width: 2, height: 2)
        let image = ClipboardImagePayload(
            data: imageData,
            thumbnailData: thumbnailData,
            width: 12,
            height: 34,
            contentHash: "hash"
        )
        storage.save([ClipboardItem(image: image)])
        let loadedItems = storage.load()

        try storage.export(loadedItems, to: exportURL)

        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exportText.contains(imageData.base64EncodedString()))
        XCTAssertTrue(exportText.contains(thumbnailData.base64EncodedString()))

        let importedItem = try XCTUnwrap(storage.importItems(from: exportURL).first)
        XCTAssertNotNil(importedItem.image?.data)
        XCTAssertNotNil(importedItem.image?.thumbnailData)
        XCTAssertEqual(importedItem.image?.width, 3)
        XCTAssertEqual(importedItem.image?.height, 4)
        XCTAssertNotNil(importedItem.image?.contentHash)
        XCTAssertNil(importedItem.image?.fileName)
        XCTAssertNil(importedItem.image?.thumbnailFileName)
    }

    func testImportRejectsExternalImagePathsBeforeTheyReachStorageWrites() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("malicious.json")
        let escapedURL = directory.appendingPathComponent("escaped.png")
        let imageData = Data([0, 1, 2, 3])
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "data":"\(imageData.base64EncodedString())",
            "fileName":"../../escaped.png",
            "width":1,
            "height":1,
            "byteCount":4
          }
        }]
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("external image paths are not allowed")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testSavingPrunedHistoryRemovesOrphanedImageFiles() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let image = ClipboardImagePayload(
            data: Data([0, 1, 2, 3]),
            thumbnailData: Data([9, 8, 7]),
            width: 1,
            height: 1
        )
        storage.save([ClipboardItem(image: image)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path).count, 2)

        try storage.saveValidated([])

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path).isEmpty)
    }

    func testFailedManifestCommitPreservesPreviousImageGeneration() throws {
        final class FaultSwitch {
            var failManifestWrite = false
        }

        let faultSwitch = FaultSwitch()
        let storage = ClipboardStorage(
            appDirectory: try makeTemporaryDirectory(),
            faultInjector: { point in
                if case .manifestWrite = point, faultSwitch.failManifestWrite {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let itemID = UUID()
        let oldData = Data([0, 1, 2, 3])
        let newData = Data([9, 8, 7, 6])
        try storage.saveValidated([
            ClipboardItem(
                id: itemID,
                image: ClipboardImagePayload(data: oldData, width: 1, height: 1)
            )
        ])
        let oldItem = try XCTUnwrap(storage.load().first)
        let oldFileName = try XCTUnwrap(oldItem.image?.fileName)
        faultSwitch.failManifestWrite = true

        XCTAssertThrowsError(
            try storage.saveValidated([
                ClipboardItem(
                    id: itemID,
                    image: ClipboardImagePayload(data: newData, width: 1, height: 1)
                )
            ])
        )

        let stillCommittedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(stillCommittedItem.image?.fileName, oldFileName)
        XCTAssertEqual(storage.imageData(for: stillCommittedItem), oldData)

        faultSwitch.failManifestWrite = false
        try storage.saveValidated([stillCommittedItem])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path),
            [oldFileName]
        )
    }

    func testImportAcceptsPortableImageRecords() throws {
        let directory = try makeTemporaryDirectory()
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let destinationStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Destination"))
        let exportURL = directory.appendingPathComponent("portable.json")
        let imageData = try makePNGData(width: 1, height: 1)
        sourceStorage.save([
            ClipboardItem(image: ClipboardImagePayload(data: imageData, width: 1, height: 1))
        ])
        try sourceStorage.export(sourceStorage.load(), to: exportURL)

        let imported = try destinationStorage.importItems(from: exportURL)
        try destinationStorage.saveValidated(imported)

        XCTAssertEqual(destinationStorage.load().count, 1)
        XCTAssertNotNil(destinationStorage.imageData(for: destinationStorage.load()[0]))
    }

    func testImportRejectsUndecodableImageData() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("invalid-image.json")
        let invalidData = Data([1, 2, 3])
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "data":"\(invalidData.base64EncodedString())",
            "width":1,
            "height":1,
            "byteCount":3
          },
          "copyCount":1
        }]
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            guard let storageError = error as? ClipboardStorageError,
                  case .invalidImportedItem = storageError else {
                XCTFail("Expected invalid imported image, got \(error)")
                return
            }
        }
    }

    func testCurrentTransferRejectsUnknownContentKindBeforeNormalization() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("unknown-kind.json")
        let json = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "text":"value",
            "contentKind":"future-kind",
            "copyCount":1
          }]
        }
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("unknown content kind “future-kind”")
            )
        }
    }

    func testCurrentTransferRejectsBlankTextAndNegativeImageDimensions() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let blankURL = directory.appendingPathComponent("blank.json")
        let blankJSON = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "text":"   ",
            "contentKind":"text",
            "copyCount":1
          }]
        }
        """
        try blankJSON.write(to: blankURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.importItems(from: blankURL))

        let imageURL = directory.appendingPathComponent("negative-dimensions.json")
        let imageData = try makePNGData(width: 1, height: 1)
        let imageJSON = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "text":"",
            "contentKind":"image",
            "copyCount":1,
            "image":{
              "data":"\(imageData.base64EncodedString())",
              "width":-1,
              "height":1,
              "byteCount":\(imageData.count)
            }
          }]
        }
        """
        try imageJSON.write(to: imageURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.importItems(from: imageURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("image dimensions must be positive")
            )
        }
    }

    func testUnsupportedTransferVersionIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("future.json")
        try """
        {"format":"CopyClipLite","version":99,"items":[]}
        """.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(error as? ClipboardStorageError, .unsupportedTransferVersion(99))
        }
    }

    func testExportPreflightsSameVersionItemLimitBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("too-many.json")
        let items = (0...ClipboardStorage.maximumImportedItems).map {
            ClipboardItem(text: "clip-\($0)", isPinned: true)
        }

        XCTAssertThrowsError(try storage.export(items, to: exportURL)) { error in
            guard case .incompatibleExport = error as? ClipboardStorageError else {
                XCTFail("Expected incompatible export, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testInvalidHistoryQuarantinesImageSidecarsWithManifest() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                )
            )
        ])
        let sidecars = try FileManager.default.contentsOfDirectory(
            atPath: storage.imageDirectoryURL.path
        )
        XCTAssertFalse(sidecars.isEmpty)
        try "broken".write(to: storage.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(storage.load().isEmpty)

        let recoveryName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first { $0.hasPrefix("Recovery-invalid-") }
        )
        let recoveredImagesURL = directory
            .appendingPathComponent(recoveryName)
            .appendingPathComponent("Images", isDirectory: true)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: recoveredImagesURL.path)),
            Set(sidecars)
        )

        storage.save([ClipboardItem(text: "new")])
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: recoveredImagesURL.path)),
            Set(sidecars)
        )
    }

    func testMissingThumbnailSelfRepairsFromFullImage() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 4, height: 3),
                    width: 4,
                    height: 3
                )
            )
        ])
        let initiallyLoaded = try XCTUnwrap(storage.load().first)
        let thumbnailName = try XCTUnwrap(initiallyLoaded.image?.thumbnailFileName)
        try FileManager.default.removeItem(
            at: storage.imageDirectoryURL.appendingPathComponent(thumbnailName)
        )

        let repairedItem = try XCTUnwrap(storage.load().first)
        let repairedData = try XCTUnwrap(storage.thumbnailData(for: repairedItem))

        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedData))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.imageDirectoryURL
                    .appendingPathComponent(try XCTUnwrap(repairedItem.image?.thumbnailFileName))
                    .path
            )
        )
    }

    func testLegacyFileBackedImageHashIsBackfilledAndPersisted() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let imageData = try makePNGData(width: 2, height: 2)
        let fileName = "legacy.png"
        try imageData.write(to: storage.imageDirectoryURL.appendingPathComponent(fileName))
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "fileName":"\(fileName)",
            "width":2,
            "height":2,
            "byteCount":\(imageData.count)
          },
          "copyCount":1
        }]
        """
        try json.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let item = try XCTUnwrap(storage.load().first)

        XCTAssertEqual(
            item.image?.contentHash,
            ClipboardImageProcessor.contentHash(for: imageData)
        )
        XCTAssertTrue(
            try String(contentsOf: storage.fileURL, encoding: .utf8)
                .contains(ClipboardImageProcessor.contentHash(for: imageData))
        )
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
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

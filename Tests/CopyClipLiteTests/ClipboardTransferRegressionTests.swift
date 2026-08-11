import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

private final class CountingClipboardImageReader: ClipboardImageReading, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var reads = 0

    init(data: Data) {
        self.data = data
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func imageData(for item: ClipboardItem) -> Data? {
        lock.withLock { reads += 1 }
        return data
    }
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.posixPermissions] as? Int ?? -1
}

@MainActor
final class ClipboardTransferRegressionTests: XCTestCase {
    func testImageDragStagingIsLazyPrivateAndRemovedWithProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CopyClipLite-DragRegression-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleURL = root.appendingPathComponent("stale-private-image.png")
        try Data("stale".utf8).write(to: staleURL)

        let reader = CountingClipboardImageReader(data: Data("canonical png".utf8))
        let factory = ClipboardDragProviderFactory(
            imageReader: reader,
            stagingDirectory: root
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(try posixPermissions(at: root), 0o700)

        var provider: NSItemProvider? = factory.provider(
            for: ClipboardItem(
                image: ClipboardImagePayload(data: nil, width: 1, height: 1)
            )
        )
        XCTAssertEqual(reader.readCount, 0, "Creating a drag provider must not read image data")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
            "Creating a drag provider must not stage image data"
        )

        let stagedPermissions: (directory: Int, file: Int) = try await withCheckedThrowingContinuation {
            continuation in
            provider?.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) {
                url,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    do {
                        continuation.resume(
                            returning: (
                                try posixPermissions(at: url.deletingLastPathComponent()),
                                try posixPermissions(at: url)
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertEqual(stagedPermissions.directory, 0o700)
        XCTAssertEqual(stagedPermissions.file, 0o600)
        XCTAssertEqual(reader.readCount, 1)

        provider = nil
        for _ in 0..<100 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testLegacyReversedTimestampsNormalizeAndReExport() throws {
        let imported = try ClipboardTransferCodec.decode(
            Data(
                """
                [{
                  "id":"00000000-0000-0000-0000-000000000001",
                  "text":"legacy",
                  "createdAt":1000,
                  "lastCopiedAt":0,
                  "copyCount":1
                }]
                """.utf8
            ),
            now: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        let item = try XCTUnwrap(imported.first)
        XCTAssertLessThanOrEqual(item.createdAt, item.lastCopiedAt)
        XCTAssertNoThrow(try ClipboardTransferCodec.encode(imported))
    }
}

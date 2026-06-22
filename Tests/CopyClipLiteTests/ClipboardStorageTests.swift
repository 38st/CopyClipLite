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

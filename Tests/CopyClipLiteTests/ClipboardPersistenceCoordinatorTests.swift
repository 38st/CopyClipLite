import Foundation
import XCTest

@testable import CopyClipLite

final class ClipboardPersistenceCoordinatorTests: XCTestCase {
    func testScheduledSaveCoalescesToLatestSnapshot() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let coordinator = ClipboardPersistenceCoordinator(storage: storage)
        let saved = expectation(description: "latest save completed")

        coordinator.scheduleSave([ClipboardItem(text: "old")]) { _ in
            XCTFail("Cancelled generation must not complete")
        }
        coordinator.scheduleSave([ClipboardItem(text: "latest")]) { result in
            if case .failure(let error) = result {
                XCTFail("Latest save failed: \(error)")
            }
            saved.fulfill()
        }

        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(storage.load().map(\.text), ["latest"])
    }

    func testFlushInvalidatesDelayedSave() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let coordinator = ClipboardPersistenceCoordinator(storage: storage)
        coordinator.scheduleSave([ClipboardItem(text: "delayed")]) { _ in
            XCTFail("Invalidated delayed save must not complete")
        }

        let flushed = try coordinator.flush([ClipboardItem(text: "flushed")])
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(flushed.map(\.text), ["flushed"])
        XCTAssertEqual(storage.load().map(\.text), ["flushed"])
    }

    func testImportCommitCreatesBackupAndLoadsCommittedCandidate() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let current = [ClipboardItem(text: "current")]
        try storage.saveValidated(current)
        let coordinator = ClipboardPersistenceCoordinator(storage: storage)
        let candidate = [ClipboardItem(text: "imported")]

        let commit = try await coordinator.commitImport(
            currentItems: current,
            candidateItems: candidate
        )

        XCTAssertEqual(commit.items, candidate)
        XCTAssertEqual(storage.load(), candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commit.backupURL.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardPersistenceCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

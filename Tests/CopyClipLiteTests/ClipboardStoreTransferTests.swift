import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("near-limit.json")
        let maximumRichText = Data(
            repeating: 0x52,
            count: ClipboardStorage.maximumImportedRichTextBytes
        )
        let maximumHTML = Data(
            repeating: 0x48,
            count: ClipboardStorage.maximumImportedRichTextBytes
        )
        sourceStorage.save(
            (0..<3).map { index in
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
        // below is the actual responsiveness guarantee. The threshold includes
        // code-coverage instrumentation overhead while still detecting a blocked
        // main actor during the multi-second import.
        XCTAssertGreaterThan(mainActorHeartbeats, 0)
        XCTAssertLessThan(maximumHeartbeatGap, .milliseconds(500))
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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
            ),
        ]
        imported.append(
            contentsOf: (0..<12).map {
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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
            ClipboardItem(text: "keep"),
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
}

import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

private final class DataRepresentationCompletionBox: @unchecked Sendable {
    typealias Completion = (Data?, Error?) -> Void

    private let lock = NSLock()
    private var completion: Completion?

    var isReady: Bool {
        lock.withLock { completion != nil }
    }

    func store(_ completion: @escaping Completion) {
        lock.withLock {
            self.completion = completion
        }
    }

    func resolve(data: Data?, error: Error?) {
        let completion = lock.withLock {
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?(data, error)
    }
}

@MainActor
final class SettingsTransferStateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDownWithError() throws {
        for suiteName in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaultsSuites.removeAll()

        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()

        try super.tearDownWithError()
    }

    func testDroppedJSONUsesValidatedPreviewPlanWithoutMutatingHistory() async throws {
        let data = try makeExportData(items: [
            ClipboardItem(text: "dropped one"),
            ClipboardItem(text: "dropped two")
        ])
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let expectedArtifact = try await store.prepareImport(
            data: data,
            sourceFileName: "Dropped.json"
        )
        let expectedPlan = store.importPlan(for: expectedArtifact)
        let provider = provider(returning: data)
        let state = SettingsTransferCoordinator()

        state.loadDroppedImport(
            from: provider,
            sourceFileName: "Dropped.json",
            store: store
        )
        try await waitUntil {
            !state.isTransferring
        }

        let actualPlan = try XCTUnwrap(state.pendingImportPlan)
        XCTAssertTrue(state.isConfirmingImport)
        XCTAssertNil(state.error)
        XCTAssertEqual(actualPlan.artifact.sourceFileName, "Dropped.json")
        XCTAssertEqual(actualPlan.artifact.items, expectedArtifact.items)
        XCTAssertEqual(actualPlan.mergeProjection, expectedPlan.mergeProjection)
        XCTAssertEqual(actualPlan.replaceProjection, expectedPlan.replaceProjection)
        XCTAssertEqual(store.items.map(\.text), ["existing"])
    }

    func testDroppedJSONLoadFailureDoesNotStartConfirmationOrMutateHistory() async throws {
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.json.identifier,
            visibility: .all
        ) { completion in
            completion(
                nil,
                NSError(
                    domain: "SettingsTransferStateTests",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Drop provider failed"]
                )
            )
            return nil
        }
        let state = SettingsTransferCoordinator()

        state.loadDroppedImport(
            from: provider,
            sourceFileName: "Broken.json",
            store: store
        )
        try await waitUntil {
            !state.isLoadingDroppedImport
        }

        XCTAssertNotNil(state.error)
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertFalse(state.isConfirmingImport)
        XCTAssertEqual(store.items.map(\.text), ["existing"])
    }

    func testCancellingDroppedJSONLoadIgnoresItsLateProviderCallback() async throws {
        let data = try makeExportData(items: [ClipboardItem(text: "late drop")])
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let completionBox = DataRepresentationCompletionBox()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.json.identifier,
            visibility: .all
        ) { completion in
            completionBox.store(completion)
            return nil
        }
        let state = SettingsTransferCoordinator()

        state.loadDroppedImport(
            from: provider,
            sourceFileName: "Late.json",
            store: store
        )
        try await waitUntil {
            state.isLoadingDroppedImport && completionBox.isReady
        }
        state.cancelCurrentTransfer()
        completionBox.resolve(data: data, error: nil)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(state.isLoadingDroppedImport)
        XCTAssertEqual(state.message, "Import cancelled.")
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertFalse(state.isConfirmingImport)
        XCTAssertEqual(store.items.map(\.text), ["existing"])
    }

    func testFileImportPreviewsAndCommitsBothStrategiesWithBackup() async throws {
        let data = try makeExportData(items: [ClipboardItem(text: "imported")])
        let url = try makeTemporaryDirectory().appendingPathComponent("Selected.json")
        try data.write(to: url)

        for strategy in [ClipboardImportStrategy.merge, .replace] {
            let store = try makeStore(items: [ClipboardItem(text: "existing")])
            let state = SettingsTransferCoordinator()
            state.prepareImport(from: url, store: store)
            XCTAssertTrue(state.isTransferring)
            try await waitUntil { !state.isTransferring }

            let plan = try XCTUnwrap(state.pendingImportPlan)
            XCTAssertTrue(state.isConfirmingImport)
            XCTAssertEqual(plan.artifact.sourceFileName, "Selected.json")
            XCTAssertEqual(store.items.map(\.text), ["existing"])
            XCTAssertEqual(store.backupInventory.count, 0)

            state.importHistory(strategy: strategy, store: store)
            XCTAssertFalse(state.isConfirmingImport)
            try await waitUntil { !state.isTransferring }

            XCTAssertNil(state.error)
            XCTAssertNil(state.pendingImportPlan)
            XCTAssertEqual(store.items, plan.candidateItems(for: strategy))
            XCTAssertTrue(state.message?.hasPrefix("Imported \(store.items.count) clips") == true)
            XCTAssertEqual(store.backupInventory.count, 1)
            let backup = try XCTUnwrap(store.backupInventory.urls.first)
            let backedUp = try await store.prepareImport(from: backup)
            XCTAssertEqual(backedUp.items.map(\.text), ["existing"])
        }
    }

    func testExportReportsResultAndPreservesHistory() async throws {
        let store = try makeStore(items: [ClipboardItem(text: "exported")])
        let originalItems = store.items
        let url = try makeTemporaryDirectory().appendingPathComponent("Saved.json")
        let state = SettingsTransferCoordinator()

        state.exportHistory(to: url, store: store)
        try await waitUntil { !state.isTransferring }

        XCTAssertNil(state.error)
        XCTAssertEqual(state.message, "Exported history to Saved.json.")
        XCTAssertEqual(store.items, originalItems)
        let artifact = try await store.prepareImport(from: url)
        XCTAssertEqual(artifact.items, originalItems)
    }

    func testTransferFailureClearsPreviewAndNextOperationClearsError() async throws {
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let state = SettingsTransferCoordinator()
        let url = try makeTemporaryDirectory().appendingPathComponent("Invalid.json")
        try Data("invalid JSON".utf8).write(to: url)

        state.prepareImport(from: url, store: store)
        try await waitUntil { !state.isTransferring }
        XCTAssertNotNil(state.error)
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertFalse(state.isConfirmingImport)
        XCTAssertEqual(store.items.map(\.text), ["existing"])

        state.exportHistory(to: url, store: store)
        XCTAssertNil(state.error)
        try await waitUntil { !state.isTransferring }
        XCTAssertEqual(state.message, "Exported history to Invalid.json.")
        XCTAssertNil(state.error)
    }

    func testExpiredImportPlanReportsFailureWithoutChangingHistory() async throws {
        let data = try makeExportData(items: [ClipboardItem(text: "imported")])
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let state = SettingsTransferCoordinator()
        state.loadDroppedImport(from: provider(returning: data), sourceFileName: "Drop.json", store: store)
        try await waitUntil { !state.isTransferring }
        XCTAssertNotNil(state.pendingImportPlan)
        store.togglePin(try XCTUnwrap(store.items.first))
        let originalItems = store.items

        state.importHistory(strategy: .replace, store: store)
        try await waitUntil { !state.isTransferring }

        XCTAssertEqual(state.error, ClipboardStorageError.importPlanExpired.localizedDescription)
        XCTAssertEqual(store.items, originalItems)
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertFalse(state.isConfirmingImport)
        XCTAssertEqual(store.backupInventory.count, 0)
        let flushed = await store.flushPendingPersist()
        XCTAssertTrue(flushed)
    }

    func testCancellationBeforeTaskStartsPreservesHistoryAndExportDestination() async throws {
        let data = try makeExportData(items: [ClipboardItem(text: "imported")])
        let url = try makeTemporaryDirectory().appendingPathComponent("Untouched.json")
        try data.write(to: url)
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let state = SettingsTransferCoordinator()

        state.exportHistory(to: url, store: store)
        state.cancelCurrentTransfer()
        try await waitUntil { !state.isTransferring }
        XCTAssertEqual(state.message, "Export cancelled.")
        XCTAssertEqual(try Data(contentsOf: url), data)

        state.prepareImport(from: url, store: store)
        state.cancelCurrentTransfer()
        try await waitUntil { !state.isTransferring }
        XCTAssertEqual(state.message, "Import cancelled.")
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertFalse(state.isConfirmingImport)

        state.prepareImport(from: url, store: store)
        try await waitUntil { !state.isTransferring }
        XCTAssertNotNil(state.pendingImportPlan)
        state.importHistory(strategy: .replace, store: store)
        state.cancelCurrentTransfer()
        try await waitUntil { !state.isTransferring }

        XCTAssertEqual(state.message, "Import cancelled before history was changed.")
        XCTAssertEqual(store.items.map(\.text), ["existing"])
        XCTAssertEqual(store.backupInventory.count, 0)
        XCTAssertNil(state.pendingImportPlan)
        XCTAssertNil(state.error)
    }

    func testCancellingCommittedImportKeepsOwnershipUntilSuccessfulCompletion() async throws {
        let gate = TransferCommitGate()
        let store = try makeStore(items: [ClipboardItem(text: "existing")], faultInjector: gate.reach)
        let data = try makeExportData(items: [ClipboardItem(text: "imported")])
        let state = SettingsTransferCoordinator()
        state.loadDroppedImport(from: provider(returning: data), sourceFileName: "Drop.json", store: store)
        try await waitUntil { !state.isTransferring }
        XCTAssertNotNil(state.pendingImportPlan)
        // The first manifest saves the current history; the second commits the import.
        gate.blockManifestWrite(number: 2)
        defer { gate.release() }
        state.importHistory(strategy: .replace, store: store)
        try await waitUntil { gate.isBlocked }

        state.cancelCurrentTransfer()
        XCTAssertTrue(state.isTransferring)
        let unwantedExport = try makeTemporaryDirectory().appendingPathComponent("Busy.json")
        state.exportHistory(to: unwantedExport, store: store)
        gate.release()
        try await waitUntil { !state.isTransferring }

        XCTAssertNil(state.error)
        XCTAssertTrue(state.message?.hasPrefix("Imported 1 clips") == true)
        XCTAssertEqual(store.items.map(\.text), ["imported"])
        XCTAssertEqual(store.backupInventory.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwantedExport.path))
    }

    func testLateCancelledDropCannotReplaceNewFileImportPreview() async throws {
        let data = try makeExportData(items: [ClipboardItem(text: "selected")])
        let url = try makeTemporaryDirectory().appendingPathComponent("Selected.json")
        try data.write(to: url)
        let store = try makeStore(items: [ClipboardItem(text: "existing")])
        let box = DataRepresentationCompletionBox()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.json.identifier, visibility: .all) {
            box.store($0)
            return nil
        }
        let state = SettingsTransferCoordinator()
        state.loadDroppedImport(from: provider, sourceFileName: "Cancelled.json", store: store)
        try await waitUntil { box.isReady }
        state.cancelCurrentTransfer()
        state.prepareImport(from: url, store: store)
        try await waitUntil { !state.isTransferring }
        box.resolve(data: data, error: nil)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(state.isConfirmingImport)
        XCTAssertEqual(state.pendingImportPlan?.artifact.sourceFileName, "Selected.json")
        XCTAssertNil(state.error)
        XCTAssertNil(state.message)
        XCTAssertEqual(store.items.map(\.text), ["existing"])
    }

    private func provider(returning data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.json.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func makeExportData(items: [ClipboardItem]) throws -> Data {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        storage.save(items)
        let url = directory.appendingPathComponent("Export.json")
        try storage.export(storage.load(), to: url)
        return try Data(contentsOf: url)
    }

    private func makeStore(
        items: [ClipboardItem],
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)? = nil
    ) throws -> ClipboardStore {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Store"),
            faultInjector: faultInjector
        )
        storage.save(items)
        let suiteName = "CopyClipLite.SettingsTransferStateTests.\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ClipboardStore(
            pasteboard: StubStorePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-SettingsTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for transfer state.")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class TransferCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let proceed = DispatchSemaphore(value: 0)
    private var remainingWrites: Int?
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }

    func blockManifestWrite(number: Int) {
        lock.withLock { remainingWrites = number }
    }

    func reach(_ point: ClipboardStorageFaultPoint) throws {
        guard point == .manifestWriteCompleted else { return }
        let shouldBlock = lock.withLock {
            guard let remainingWrites else { return false }
            self.remainingWrites = remainingWrites - 1
            guard remainingWrites == 1 else { return false }
            self.remainingWrites = nil
            blocked = true
            return true
        }
        guard shouldBlock else { return }
        guard proceed.wait(timeout: .now() + 5) == .success else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func release() { proceed.signal() }
}

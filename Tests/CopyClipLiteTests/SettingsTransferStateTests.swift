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
            !state.isLoadingDroppedImport && state.task == nil
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

    private func makeStore(items: [ClipboardItem]) throws -> ClipboardStore {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        storage.save(items)
        let suiteName = "CopyClipLite.SettingsTransferStateTests.\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ClipboardStore(
            pasteboard: NSPasteboard(
                name: NSPasteboard.Name(
                    "CopyClipLite.SettingsTransferStateTests.\(UUID().uuidString)"
                )
            ),
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

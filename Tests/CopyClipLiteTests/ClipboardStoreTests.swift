import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

actor DelayedImageProcessor: ClipboardImageProcessing {
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

actor SequencedImageProcessor: ClipboardImageProcessing {
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

actor RecordingDelayedImageProcessor: ClipboardImageProcessing {
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

actor ExternalizingStressImageProcessor: ClipboardImageProcessing {
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

final class ManualClipboardClock: @unchecked Sendable {
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

    func setNow(_ date: Date) {
        lock.lock()
        currentDate = date
        lock.unlock()
    }

    func wakeAllSleepers() {
        lock.lock()
        let ready = sleepers
        sleepers.removeAll()
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }
}

final class StubPasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
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

final class SelectiveFailurePasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
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
    var tempDirectories: [URL] = []
    var defaultsSuites: [String] = []

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

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    func makeDefaults() -> UserDefaults {
        let suiteName = "CopyClipLiteTests-\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("CopyClipLiteTests-\(UUID().uuidString)"))
    }

    func makePasteControllerWithPermissionError(
        item: ClipboardItem,
        store: ClipboardStore
    ) -> PasteTargetController {
        let controller = PasteTargetController(
            runtime: PasteTargetRuntime(
                isAccessibilityGranted: { false },
                requestAccessibilityPermission: {},
                simulatePaste: { _ in false },
                openAccessibilitySettings: {},
                hideApplication: {},
                restoreApplication: {}
            ),
            observeWorkspace: false
        )
        controller.paste(item, using: store)
        return controller
    }

    func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
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

    func makeSolidPNGData(width: Int, height: Int) throws -> Data {
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

    func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    func waitForCapturedItem(in store: ClipboardStore) async throws {
        for _ in 0..<100 where store.items.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.items.isEmpty, "Timed out waiting for background image processing")
    }

    func waitForCopyCount(_ copyCount: Int, in store: ClipboardStore) async throws {
        for _ in 0..<100 where store.items.first?.copyCount != copyCount {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.items.first?.copyCount, copyCount)
    }

    func assertReadableImageData(
        _ data: Data?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(data, file: file, line: line)
        XCTAssertNotNil(NSImage(data: data), file: file, line: line)
    }

    func assertPendingPersistCannotOverwriteImport(
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
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source"))
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

    func assertAsyncImportedImageRemainsCopyableAfterRelaunch(
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

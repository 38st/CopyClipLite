import AppKit
import Foundation
import XCTest
@testable import CopyClipLite

@MainActor
private final class FakePasteTargetApplication: PasteTargetApplication {
    var pasteBundleIdentifier: String? = "com.example.Target"
    var pasteLocalizedName: String? = "Target"
    var pasteProcessIdentifier: pid_t = 42
    var pasteIsTerminated = false
    var pasteIsActive = false
    var activationResult = true

    func activateForPaste() -> Bool {
        if activationResult {
            pasteIsActive = true
        }
        return activationResult
    }
}

@MainActor
private final class PasteRuntimeState {
    var permissionGranted = true
    var hideCount = 0
    var restoreCount = 0
    var simulateCount = 0
}

@MainActor
final class PasteTargetControllerTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDownWithError() throws {
        for suiteName in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testActivationFailureRestoresApplicationAndShowsError() throws {
        let target = FakePasteTargetApplication()
        target.activationResult = false
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)

        XCTAssertEqual(state.hideCount, 1)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertNotNil(controller.lastError)
    }

    func testSuccessfulPasteAttemptUsesVisibleTargetAndStaysHidden() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        XCTAssertEqual(controller.targetApplicationName, "Target")
        controller.paste(item, using: store)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(state.hideCount, 1)
        XCTAssertEqual(state.restoreCount, 0)
        XCTAssertEqual(state.simulateCount, 1)
        XCTAssertNil(controller.lastError)
    }

    func testPermissionFailureDoesNotHideOrCopy() throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        state.permissionGranted = false
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()
        let initialCopyCount = item.copyCount

        controller.paste(item, using: store)

        XCTAssertEqual(state.hideCount, 0)
        XCTAssertEqual(state.restoreCount, 0)
        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(store.items.first?.copyCount, initialCopyCount)
        XCTAssertNotNil(controller.lastError)
    }

    private func makeController(
        target: FakePasteTargetApplication,
        state: PasteRuntimeState
    ) -> PasteTargetController {
        let runtime = PasteTargetRuntime(
            isAccessibilityGranted: { state.permissionGranted },
            requestAccessibilityPermission: {},
            simulatePaste: {
                state.simulateCount += 1
                return true
            },
            openAccessibilitySettings: {},
            hideApplication: { state.hideCount += 1 },
            restoreApplication: { state.restoreCount += 1 }
        )
        return PasteTargetController(
            initialTarget: target,
            runtime: runtime,
            observeWorkspace: false,
            activationPollCount: 1,
            activationPollNanoseconds: 1_000_000,
            stabilizationNanoseconds: 0
        )
    }

    private func makeStoreAndItem() throws -> (ClipboardStore, ClipboardItem) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteTargetControllerTests-\(UUID().uuidString)")
        tempDirectories.append(directory)
        let storage = ClipboardStorage(appDirectory: directory)
        storage.save([ClipboardItem(text: "paste me")])
        let suiteName = "PasteTargetControllerTests-\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ClipboardStore(
            pasteboard: NSPasteboard(name: .init("PasteTargetControllerTests-\(UUID().uuidString)")),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        return (store, try XCTUnwrap(store.items.first))
    }
}

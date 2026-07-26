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
    var becomesActiveOnActivation = true

    func activateForPaste() -> Bool {
        if activationResult, becomesActiveOnActivation {
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
    var simulateResult = true
    var openSettingsCount = 0
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
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
        XCTAssertEqual(
            controller.attemptState,
            .failed(
                message: controller.lastError ?? "",
                clipWasCopied: true
            )
        )
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
        XCTAssertEqual(controller.attemptState, .postAttempted(target: "Target"))
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
        XCTAssertTrue(controller.lastError?.contains("Nothing was copied") == true)
    }

    func testActivationTimeoutRestoresUIAndReportsClipboardOutcome() async throws {
        let target = FakePasteTargetApplication()
        target.becomesActiveOnActivation = false
        let state = PasteRuntimeState()
        let controller = makeController(
            target: target,
            state: state,
            activationPollCount: 2
        )
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
    }

    func testNewFailedRequestCancelsOlderPendingPasteWithoutOverwritingItsError() async throws {
        let target = FakePasteTargetApplication()
        target.becomesActiveOnActivation = false
        let state = PasteRuntimeState()
        let controller = makeController(
            target: target,
            state: state,
            activationPollCount: 20
        )
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)
        state.permissionGranted = false
        controller.paste(item, using: store)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(state.simulateCount, 0)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("Nothing was copied") == true)
    }

    func testPasteEventFailureRestoresUIAndReportsCopiedClip() async throws {
        let target = FakePasteTargetApplication()
        let state = PasteRuntimeState()
        state.simulateResult = false
        let controller = makeController(target: target, state: state)
        let (store, item) = try makeStoreAndItem()

        controller.paste(item, using: store)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(state.simulateCount, 1)
        XCTAssertEqual(state.restoreCount, 1)
        XCTAssertTrue(controller.lastError?.contains("still on your clipboard") == true)
    }

    func testAccessibilitySettingsActivationDoesNotReplaceRememberedTarget() {
        let target = FakePasteTargetApplication()
        let settings = FakePasteTargetApplication()
        settings.pasteLocalizedName = "System Settings"
        settings.pasteBundleIdentifier = "com.apple.systempreferences"
        settings.pasteProcessIdentifier = 99
        let state = PasteRuntimeState()
        let controller = makeController(target: target, state: state)

        controller.openAccessibilitySettings()
        controller.handleActivation(settings)

        XCTAssertEqual(state.openSettingsCount, 1)
        XCTAssertEqual(controller.targetApplicationName, "Target")
    }

    private func makeController(
        target: FakePasteTargetApplication,
        state: PasteRuntimeState,
        activationPollCount: Int = 1
    ) -> PasteTargetController {
        let runtime = PasteTargetRuntime(
            isAccessibilityGranted: { state.permissionGranted },
            requestAccessibilityPermission: {},
            simulatePaste: {
                state.simulateCount += 1
                return state.simulateResult
            },
            openAccessibilitySettings: { state.openSettingsCount += 1 },
            hideApplication: { state.hideCount += 1 },
            restoreApplication: { state.restoreCount += 1 }
        )
        return PasteTargetController(
            initialTarget: target,
            runtime: runtime,
            observeWorkspace: false,
            activationPollCount: activationPollCount,
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

import Carbon
import Foundation
import XCTest
@testable import CopyClipLite

@MainActor
private final class FakeHotkeyRegistrar: GlobalHotkeyRegistering {
    var isRegistered = false
    var activeConfig: HotkeyConfig?
    var installResult: Result<Void, GlobalHotkeyRegistrationError> = .success(())
    var nextRegistrationResult: Result<Void, GlobalHotkeyRegistrationError> = .success(())
    var registrationAttempts: [HotkeyConfig] = []
    var didSuspend = false
    var action: (@MainActor @Sendable () -> Void)?

    func installHandler(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, GlobalHotkeyRegistrationError> {
        self.action = action
        return installResult
    }

    func replace(with config: HotkeyConfig) -> Result<Void, GlobalHotkeyRegistrationError> {
        registrationAttempts.append(config)
        switch nextRegistrationResult {
        case .success:
            activeConfig = config
            isRegistered = true
            didSuspend = false
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }

    func suspend() {
        didSuspend = true
        isRegistered = false
    }

    func resume() -> Result<Void, GlobalHotkeyRegistrationError> {
        guard didSuspend, let activeConfig else {
            return .success(())
        }
        return replace(with: activeConfig)
    }
}

@MainActor
final class GlobalHotkeyControllerTests: XCTestCase {
    func testShiftOnlyShortcutIsRejected() {
        let config = HotkeyConfig(keyCode: kVK_ANSI_A, modifiers: shiftKey)

        XCTAssertEqual(config.validationError, .unsafeModifierCombination)
    }

    func testInvalidPersistedShortcutFallsBackToDefault() throws {
        let suiteName = "GlobalHotkeyControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalid = HotkeyConfig(keyCode: -1, modifiers: cmdKey)
        defaults.set(try JSONEncoder().encode(invalid), forKey: HotkeyConfig.DefaultsKey.hotkeyConfig)

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testFailedReplacementKeepsPreviousRegistrationAndConfig() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let attempted = HotkeyConfig(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey)
        registrar.nextRegistrationResult = .failure(
            .registration(OSStatus(eventHotKeyExistsErr), shortcut: attempted.displayString)
        )

        controller.updateConfig(attempted)

        XCTAssertEqual(controller.config, .default)
        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.activeConfig, .default)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testHandlerFailurePreventsRegistration() {
        let registrar = FakeHotkeyRegistrar()
        registrar.installResult = .failure(.handler(-1))

        let controller = GlobalHotkeyController(config: .default, registrar: registrar)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertTrue(registrar.registrationAttempts.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRecordingSuspendsAndRestoresCurrentShortcut() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)

        controller.setRecording(true)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertTrue(registrar.didSuspend)

        controller.setRecording(false)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.activeConfig, .default)
    }
}

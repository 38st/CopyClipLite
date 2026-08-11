import Foundation
import XCTest
@testable import CopyClipLite

private final class StubLoginItemService: LoginItemServicing, @unchecked Sendable {
    var status: LoginItemStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }

    func openSettings() {
        openSettingsCount += 1
    }
}

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testApprovalPendingDisablesByUnregistering() {
        let service = StubLoginItemService(status: .requiresApproval)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNil(controller.errorMessage)
    }

    func testApprovalPendingEnableOpensSettingsWithoutRegisteringAgain() {
        let service = StubLoginItemService(status: .requiresApproval)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.openSettingsCount, 1)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testEnabledDisablesByUnregistering() {
        let service = StubLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRegistrationFailurePreservesActualStateAndShowsError() {
        let service = StubLoginItemService(status: .notRegistered)
        service.registerError = CocoaError(.fileWriteUnknown)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testEnabledEnableAndNotRegisteredDisableAreNoOps() {
        let enabledService = StubLoginItemService(status: .enabled)
        let enabledController = LoginItemController(service: enabledService)
        enabledController.setEnabled(true)
        XCTAssertEqual(enabledService.registerCount, 0)
        XCTAssertEqual(enabledService.unregisterCount, 0)
        XCTAssertEqual(enabledController.status, .enabled)

        let offService = StubLoginItemService(status: .notRegistered)
        let offController = LoginItemController(service: offService)
        offController.setEnabled(false)
        XCTAssertEqual(offService.registerCount, 0)
        XCTAssertEqual(offService.unregisterCount, 0)
        XCTAssertEqual(offController.status, .notRegistered)
    }

    func testNotRegisteredEnableRegistersSuccessfully() {
        let service = StubLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testUnavailableAndUnknownStatesHaveDeterministicTransitions() {
        for initialStatus in [LoginItemStatus.notFound, .unknown] {
            let enableService = StubLoginItemService(status: initialStatus)
            let enableController = LoginItemController(service: enableService)
            enableController.setEnabled(true)
            XCTAssertEqual(enableService.registerCount, 1)
            XCTAssertEqual(enableController.status, .enabled)

            let disableService = StubLoginItemService(status: initialStatus)
            let disableController = LoginItemController(service: disableService)
            disableController.setEnabled(false)
            XCTAssertEqual(disableService.unregisterCount, 1)
            XCTAssertEqual(disableController.status, .notRegistered)
        }
    }

    func testUnregisterFailurePreservesActualStateAndClearsAfterRecovery() {
        let service = StubLoginItemService(status: .enabled)
        service.unregisterError = CocoaError(.fileWriteUnknown)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.errorMessage)

        service.unregisterError = nil
        controller.setEnabled(false)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNil(controller.errorMessage)
    }

    func testRefreshClearsFailureAfterExternalStateRecovery() {
        let service = StubLoginItemService(status: .notRegistered)
        service.registerError = CocoaError(.fileWriteUnknown)
        let controller = LoginItemController(service: service)
        controller.setEnabled(true)
        XCTAssertNotNil(controller.errorMessage)

        service.status = .enabled
        controller.refresh()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.errorMessage)
    }
}

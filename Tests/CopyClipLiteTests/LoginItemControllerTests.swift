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
}

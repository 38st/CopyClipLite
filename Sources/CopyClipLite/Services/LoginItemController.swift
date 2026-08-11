import Foundation
import ServiceManagement

enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unknown
}

protocol LoginItemServicing: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

struct SystemLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemServicing

    init(service: any LoginItemServicing = SystemLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var statusText: String {
        switch status {
        case .enabled:
            "Enabled"
        case .notRegistered:
            "Off"
        case .requiresApproval:
            "Needs approval"
        case .notFound:
            "Unavailable"
        case .unknown:
            "Unknown"
        }
    }

    func refresh() {
        let refreshedStatus = service.status
        if refreshedStatus != status {
            errorMessage = nil
        }
        status = refreshedStatus
    }

    func setEnabled(_ shouldEnable: Bool) {
        do {
            if shouldEnable {
                switch status {
                case .enabled:
                    break
                case .requiresApproval:
                    service.openSettings()
                case .notRegistered, .notFound, .unknown:
                    try service.register()
                }
            } else if status != .notRegistered {
                try service.unregister()
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    func openLoginItemsSettings() {
        service.openSettings()
    }
}

import Foundation
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    init() {
        self.status = SMAppService.mainApp.status
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
        @unknown default:
            "Unknown"
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ shouldEnable: Bool) {
        do {
            if shouldEnable {
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }

            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

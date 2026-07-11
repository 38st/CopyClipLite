import AppKit
import Foundation

@MainActor
final class PasteTargetController: ObservableObject {
    @Published private(set) var isAccessibilityGranted = PasteSimulator.isAccessibilityGranted
    @Published private(set) var lastError: String?

    private var lastExternalApplication: NSRunningApplication?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private var pendingPasteTask: Task<Void, Never>?

    init() {
        captureCurrentTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.rememberIfExternal(application)
            }
        }
    }

    deinit {
        pendingPasteTask?.cancel()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    var targetApplicationName: String? {
        lastExternalApplication?.localizedName
    }

    func captureCurrentTarget() {
        rememberIfExternal(NSWorkspace.shared.frontmostApplication)
    }

    func refreshPermission() {
        isAccessibilityGranted = PasteSimulator.isAccessibilityGranted
        if isAccessibilityGranted, lastError == Self.permissionError {
            lastError = nil
        }
    }

    func requestPermission() {
        PasteSimulator.requestAccessibilityPermission()
        refreshPermission()
    }

    func openAccessibilitySettings() {
        PasteSimulator.openAccessibilitySettings()
    }

    func paste(_ item: ClipboardItem, using store: ClipboardStore) {
        refreshPermission()
        guard isAccessibilityGranted else {
            lastError = Self.permissionError
            NSSound.beep()
            return
        }
        guard let target = lastExternalApplication, !target.isTerminated else {
            lastError = "Open the destination app once, then try Direct Paste again."
            NSSound.beep()
            return
        }
        guard store.copy(item) else {
            lastError = store.storageErrorMessage ?? "The clip could not be copied."
            NSSound.beep()
            return
        }

        pendingPasteTask?.cancel()
        lastError = nil
        NSApp.hide(nil)
        guard target.activate(options: []) else {
            lastError = "\(target.localizedName ?? "The destination app") could not be activated."
            return
        }

        pendingPasteTask = Task { @MainActor [weak self, weak target] in
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                if target?.isActive == true { break }
            }
            guard target?.isActive == true else {
                self?.lastError = "The destination app did not become active, so nothing was pasted."
                return
            }
            guard PasteSimulator.simulatePaste() else {
                self?.lastError = "macOS could not create the paste event."
                return
            }
            self?.lastError = nil
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func rememberIfExternal(_ application: NSRunningApplication?) {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        lastExternalApplication = application
    }

    private static let permissionError = "Direct Paste needs Accessibility permission. Open Settings to grant it."
}

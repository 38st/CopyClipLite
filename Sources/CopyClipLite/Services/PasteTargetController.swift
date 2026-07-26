import AppKit
import Foundation

@MainActor
protocol PasteTargetApplication: AnyObject {
    var pasteBundleIdentifier: String? { get }
    var pasteLocalizedName: String? { get }
    var pasteProcessIdentifier: pid_t { get }
    var pasteIsTerminated: Bool { get }
    var pasteIsActive: Bool { get }
    func activateForPaste() -> Bool
}

extension NSRunningApplication: PasteTargetApplication {
    var pasteBundleIdentifier: String? { bundleIdentifier }
    var pasteLocalizedName: String? { localizedName }
    var pasteProcessIdentifier: pid_t { processIdentifier }
    var pasteIsTerminated: Bool { isTerminated }
    var pasteIsActive: Bool { isActive }

    func activateForPaste() -> Bool {
        activate(options: [])
    }
}

@MainActor
struct PasteTargetRuntime {
    var isAccessibilityGranted: () -> Bool
    var requestAccessibilityPermission: () -> Void
    var simulatePaste: () -> Bool
    var openAccessibilitySettings: () -> Void
    var hideApplication: () -> Void
    var restoreApplication: () -> Void
    var frontmostApplication: () -> (any PasteTargetApplication)? = {
        NSWorkspace.shared.frontmostApplication
    }
    var observeApplicationActivations: (
        @escaping @MainActor @Sendable (any PasteTargetApplication) -> Void
    ) -> () -> Void = { handler in
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let observer = NotificationObserverToken(
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication else {
                    return
                }
                MainActor.assumeIsolated {
                    handler(application)
                }
            }
        )
        return {
            notificationCenter.removeObserver(observer.value)
        }
    }
    var monotonicNanoseconds: () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }
    var sleepNanoseconds: (UInt64) async throws -> Void = {
        try await Task.sleep(nanoseconds: $0)
    }

    static let live = PasteTargetRuntime(
        isAccessibilityGranted: { PasteSimulator.isAccessibilityGranted },
        requestAccessibilityPermission: { PasteSimulator.requestAccessibilityPermission() },
        simulatePaste: { PasteSimulator.simulatePaste() },
        openAccessibilitySettings: { PasteSimulator.openAccessibilitySettings() },
        hideApplication: { NSApp.hide(nil) },
        restoreApplication: {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    )
}

enum PasteAttemptState: Equatable {
    case idle
    case preflighting
    case activating(target: String)
    case waitingForTarget(target: String)
    case posting(target: String)
    case postAttempted(target: String)
    case failed(message: String, clipWasCopied: Bool)
}

@MainActor
final class PasteTargetController: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool
    @Published private(set) var lastError: String?
    @Published private(set) var attemptState: PasteAttemptState = .idle

    private var lastExternalApplication: (any PasteTargetApplication)?
    nonisolated(unsafe) private var cancelActivationObservation: (() -> Void)?
    private var pendingPasteTask: Task<Void, Never>?
    private var pendingPasteOwnsHiddenUI = false
    private var pasteRequestGeneration: UInt64 = 0
    private var isPreservingTargetForSystemSettings = false
    private let runtime: PasteTargetRuntime
    private let activationTimeoutNanoseconds: UInt64
    private let activationPollNanoseconds: UInt64
    private let stabilizationNanoseconds: UInt64

    init(
        initialTarget: (any PasteTargetApplication)? = nil,
        runtime: PasteTargetRuntime? = nil,
        observeWorkspace: Bool = true,
        activationPollCount: Int = 20,
        activationPollNanoseconds: UInt64 = 50_000_000,
        activationTimeoutNanoseconds: UInt64? = nil,
        stabilizationNanoseconds: UInt64 = 100_000_000
    ) {
        let runtime = runtime ?? .live
        self.runtime = runtime
        self.isAccessibilityGranted = runtime.isAccessibilityGranted()
        self.lastExternalApplication = initialTarget
        let pollInterval = max(activationPollNanoseconds, 1)
        self.activationPollNanoseconds = pollInterval
        self.activationTimeoutNanoseconds = activationTimeoutNanoseconds
            ?? Self.clampedProduct(max(activationPollCount, 0), pollInterval)
        self.stabilizationNanoseconds = stabilizationNanoseconds

        if initialTarget == nil {
            captureCurrentTarget()
        }
        if observeWorkspace {
            installActivationObserver()
        }
    }

    deinit {
        pendingPasteTask?.cancel()
        cancelActivationObservation?()
    }

    var targetApplicationName: String? {
        lastExternalApplication?.pasteLocalizedName
    }

    func captureCurrentTarget() {
        rememberIfExternal(runtime.frontmostApplication())
    }

    func refreshPermission() {
        isAccessibilityGranted = runtime.isAccessibilityGranted()
        if isAccessibilityGranted, lastError == Self.permissionError {
            lastError = nil
        }
    }

    func requestPermission() {
        runtime.requestAccessibilityPermission()
        refreshPermission()
    }

    func openAccessibilitySettings() {
        isPreservingTargetForSystemSettings = true
        runtime.openAccessibilitySettings()
    }

    func paste(_ item: ClipboardItem, using store: ClipboardStore) {
        cancelPendingPaste(restoreUI: true)
        attemptState = .preflighting
        refreshPermission()
        guard isAccessibilityGranted else {
            fail(Self.permissionError, restoreUI: false, clipWasCopied: false)
            return
        }
        guard let target = lastExternalApplication, !target.pasteIsTerminated else {
            fail(
                "Open the destination app once, then try Direct Paste again.",
                restoreUI: false,
                clipWasCopied: false
            )
            return
        }
        guard store.copy(item) else {
            fail(
                store.storageErrorMessage ?? "The clip could not be copied.",
                restoreUI: false,
                clipWasCopied: false
            )
            return
        }

        pasteRequestGeneration &+= 1
        let requestGeneration = pasteRequestGeneration
        let targetName = target.pasteLocalizedName ?? "The destination app"
        lastError = nil
        attemptState = .activating(target: targetName)
        runtime.hideApplication()
        pendingPasteOwnsHiddenUI = true
        guard target.activateForPaste() else {
            fail(
                "\(targetName) could not be activated.",
                restoreUI: true,
                clipWasCopied: true
            )
            return
        }

        attemptState = .waitingForTarget(target: targetName)
        pendingPasteTask = Task { @MainActor [weak self, target] in
            guard let self else { return }
            let deadline = Self.clampedSum(
                self.runtime.monotonicNanoseconds(),
                self.activationTimeoutNanoseconds
            )
            while !target.pasteIsActive {
                let now = self.runtime.monotonicNanoseconds()
                guard now < deadline else { break }
                let remaining = deadline - now
                do {
                    try await self.runtime.sleepNanoseconds(
                        min(self.activationPollNanoseconds, remaining)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.pasteRequestGeneration == requestGeneration else {
                    return
                }
            }

            guard target.pasteIsActive else {
                self.fail(
                    "The destination app did not become active, so nothing was pasted.",
                    restoreUI: true,
                    clipWasCopied: true
                )
                return
            }

            do {
                try await self.runtime.sleepNanoseconds(self.stabilizationNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.pasteRequestGeneration == requestGeneration else {
                return
            }
            guard !target.pasteIsTerminated,
                  target.pasteIsActive else {
                self.fail(
                    "The destination app was no longer ready, so nothing was pasted.",
                    restoreUI: true,
                    clipWasCopied: true
                )
                return
            }

            self.refreshPermission()
            guard self.isAccessibilityGranted else {
                self.fail(
                    Self.permissionError,
                    restoreUI: true,
                    clipWasCopied: true
                )
                return
            }
            self.attemptState = .posting(target: targetName)
            guard self.runtime.simulatePaste() else {
                self.fail(
                    "macOS could not create the paste event.",
                    restoreUI: true,
                    clipWasCopied: true
                )
                return
            }

            self.pendingPasteTask = nil
            self.pendingPasteOwnsHiddenUI = false
            self.lastError = nil
            self.attemptState = .postAttempted(target: targetName)
        }
    }

    func dismissError() {
        lastError = nil
    }

    private func installActivationObserver() {
        cancelActivationObservation = runtime.observeApplicationActivations { [weak self] application in
            self?.handleActivation(application)
        }
    }

    func handleActivation(_ application: any PasteTargetApplication) {
        let isOwnApplication = application.pasteBundleIdentifier == Bundle.main.bundleIdentifier
            || application.pasteProcessIdentifier == ProcessInfo.processInfo.processIdentifier
        if isOwnApplication {
            isPreservingTargetForSystemSettings = false
            return
        }
        guard !isPreservingTargetForSystemSettings else {
            return
        }
        rememberIfExternal(application)
    }

    private func rememberIfExternal(_ application: (any PasteTargetApplication)?) {
        guard let application,
              application.pasteBundleIdentifier != Bundle.main.bundleIdentifier,
              application.pasteProcessIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        lastExternalApplication = application
    }

    private func cancelPendingPaste(restoreUI: Bool = false) {
        let shouldRestore = restoreUI
            && pendingPasteTask != nil
            && pendingPasteOwnsHiddenUI
        pasteRequestGeneration &+= 1
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        pendingPasteOwnsHiddenUI = false
        if shouldRestore {
            runtime.restoreApplication()
        }
    }

    private func fail(
        _ message: String,
        restoreUI: Bool,
        clipWasCopied: Bool
    ) {
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        let outcome = clipWasCopied
            ? "The clip is still on your clipboard."
            : "Nothing was copied."
        let fullMessage = "\(message) \(outcome)"
        lastError = fullMessage
        attemptState = .failed(
            message: fullMessage,
            clipWasCopied: clipWasCopied
        )
        if restoreUI {
            runtime.restoreApplication()
            pendingPasteOwnsHiddenUI = false
        }
        NSSound.beep()
    }

    private static let permissionError = "Direct Paste needs Accessibility permission. Open Settings to grant it."

    private static func clampedProduct(_ lhs: Int, _ rhs: UInt64) -> UInt64 {
        guard let lhs = UInt64(exactly: lhs) else { return 0 }
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : result
    }

    private static func clampedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

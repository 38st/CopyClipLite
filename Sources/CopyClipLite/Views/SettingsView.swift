import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @ObservedObject var pasteTargetController: PasteTargetController
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase
    @State private var transferMessage: String?
    @State private var transferError: String?
    @State private var pendingImportURL: URL?
    @State private var pendingImportPreview: ClipboardImportPreview?
    @State private var isConfirmingImport = false
    @State private var isConfirmingExport = false

    private var historyLimit: Binding<Int> {
        Binding(get: { store.historyLimit }, set: { store.setHistoryLimit($0) })
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
    }

    private var monitoringEnabled: Binding<Bool> {
        Binding(get: { store.isMonitoringEnabled }, set: { store.setMonitoringEnabled($0) })
    }

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }

            privacySettings
                .tabItem { Label("Privacy", systemImage: "hand.raised") }

            shortcutSettings
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            dataSettings
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 440)
        .padding(.top, 8)
        .onAppear {
            loginItem.refresh()
            pasteTargetController.refreshPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loginItem.refresh()
                pasteTargetController.refreshPermission()
            }
        }
        .confirmationDialog(
            "Export Clipboard History?",
            isPresented: $isConfirmingExport,
            titleVisibility: .visible
        ) {
            Button("Export Plaintext JSON") { performExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The export contains the full text and images in your history without encryption. Store and share it carefully.")
        }
        .confirmationDialog(
            importConfirmationTitle,
            isPresented: $isConfirmingImport,
            titleVisibility: .visible
        ) {
            Button("Merge with Existing History") { performImport(strategy: .merge) }
            Button("Replace Existing History", role: .destructive) { performImport(strategy: .replace) }
            Button("Cancel", role: .cancel) { clearPendingImport() }
        } message: {
            Text("A private backup is created before either action. Replace removes the current history after the backup succeeds.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("History") {
                Stepper(value: historyLimit, in: 10...200, step: 10) {
                    LabeledContent("Unpinned clip limit", value: "\(store.historyLimit)")
                }
                Toggle("Keep pinned items when clearing", isOn: $store.keepPinnedOnClear)
            }

            Section("Monitoring") {
                Toggle("Monitor clipboard", isOn: monitoringEnabled)
                LabeledContent("Status", value: store.monitoringStatusText)
                Menu {
                    ForEach(ClipboardPauseDuration.allCases) { duration in
                        Button(duration.title) { store.pauseMonitoring(for: duration) }
                    }
                } label: {
                    Label("Pause Monitoring", systemImage: "pause.circle")
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: launchAtLogin)
                LabeledContent("Status", value: loginItem.statusText)
                if loginItem.needsApproval {
                    Button("Open Login Items Settings") { loginItem.openLoginItemsSettings() }
                }
                if let errorMessage = loginItem.errorMessage {
                    SettingsErrorText(errorMessage)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("Retention") {
                Picker("Auto-clear unpinned clips", selection: $store.retentionPolicy) {
                    ForEach(ClipboardRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Pinned clips", value: "Never auto-clear")
                Toggle("Clear unpinned history when quitting", isOn: $store.clearUnpinnedOnQuit)
            }

            Section("Source Exclusions") {
                Text("macOS does not expose guaranteed clipboard ownership. CopyClip checks the active app at the instant a change is detected and also skips concealed or transient clipboard data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.ignoredApplications.isEmpty {
                    Text("No excluded apps")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.ignoredApplications) { application in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.name)
                                Text(application.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeIgnoredApplication(application)
                            } label: {
                                Label("Remove \(application.name)", systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Button {
                    addIgnoredApplication()
                } label: {
                    Label("Exclude an App", systemImage: "plus")
                }
            }

            Section("At Rest") {
                Text("History is stored locally with owner-only file permissions. It is not separately encrypted, so enable FileVault when clipboard confidentiality matters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutSettings: some View {
        Form {
            Section("Global Hotkey") {
                LabeledContent("Open clipboard search") {
                    HotkeyRecorder(config: hotkeyController.config) { newConfig in
                        hotkeyController.updateConfig(newConfig)
                    } onRecordingChanged: { isRecording in
                        hotkeyController.setRecording(isRecording)
                    }
                    .frame(width: 180, height: 28)
                }

                if let errorMessage = hotkeyController.errorMessage {
                    SettingsErrorText(errorMessage)
                }

                Button("Reset to Default (⌥⌘V)") {
                    hotkeyController.updateConfig(.default)
                }
            }

            Section("Direct Paste") {
                Toggle("Copy and paste into the previous app", isOn: $store.directPasteEnabled)
                Text("Direct Paste returns focus to the last app you used before sending ⌘V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if store.directPasteEnabled {
                    LabeledContent(
                        "Paste target",
                        value: pasteTargetController.targetApplicationName ?? "Open a destination app"
                    )
                    LabeledContent(
                        "Accessibility permission",
                        value: pasteTargetController.isAccessibilityGranted ? "Granted" : "Required"
                    )
                    if !pasteTargetController.isAccessibilityGranted {
                        HStack {
                            Button("Request Permission") { pasteTargetController.requestPermission() }
                            Button("Open System Settings") { pasteTargetController.openAccessibilitySettings() }
                        }
                    }
                }

                if let errorMessage = pasteTargetController.lastError {
                    SettingsErrorText(errorMessage)
                }
            }

            Section("List Keyboard Controls") {
                LabeledContent("Move selection", value: "↑ / ↓")
                LabeledContent("Use selected clip", value: "Return")
                LabeledContent("Pin or unpin", value: "⌘P")
                LabeledContent("Delete selected clip", value: "⌘⌫")
                LabeledContent("Focus search", value: "⌘F")
            }
        }
        .formStyle(.grouped)
    }

    private var dataSettings: some View {
        Form {
            Section("Storage") {
                LabeledContent("History file") {
                    Text(store.storageLocation.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.storageLocation])
                }
                if let errorMessage = store.storageErrorMessage {
                    SettingsErrorText(errorMessage)
                }
            }

            Section("Transfer") {
                Text("Exports are unencrypted JSON. Imports are validated, previewed, and backed up before they can change your current history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export…") { isConfirmingExport = true }
                    Button("Import…") { chooseImport() }
                }
                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let transferError {
                    SettingsErrorText(transferError)
                }
            }

            Section("Updates") {
                LabeledContent("Installed version", value: updateChecker.currentVersion)
                switch updateChecker.state {
                case .idle:
                    Button("Check for Updates") { updateChecker.check() }
                case .checking:
                    ProgressView("Checking GitHub Releases…")
                        .controlSize(.small)
                case .upToDate:
                    Label("CopyClip Lite is up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Check Again") { updateChecker.check() }
                case let .updateAvailable(version, _):
                    Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                    Button("Open Notarized Release") { updateChecker.openAvailableUpdate() }
                case let .failed(message):
                    SettingsErrorText(message)
                    Button("Try Again") { updateChecker.check() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var importConfirmationTitle: String {
        guard let preview = pendingImportPreview else { return "Import Clipboard History?" }
        let clipWord = preview.itemCount == 1 ? "clip" : "clips"
        return "Import \(preview.itemCount) \(clipWord) (\(preview.textCount) text, \(preview.imageCount) images)?"
    }

    private func addIgnoredApplication() {
        guard let application = ApplicationPickerPanel.chooseApplication() else { return }
        store.addIgnoredApplication(application)
    }

    private func performExport() {
        transferMessage = nil
        transferError = nil
        guard let url = ClipboardHistoryTransferPanel.exportDestinationURL(
            defaultFileName: "CopyClip-Lite-History.json"
        ) else { return }

        do {
            try store.exportHistory(to: url)
            transferMessage = "Exported history to \(url.lastPathComponent)."
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func chooseImport() {
        transferMessage = nil
        transferError = nil
        guard let url = ClipboardHistoryTransferPanel.importSourceURL() else { return }

        do {
            pendingImportURL = url
            pendingImportPreview = try store.importPreview(from: url)
            isConfirmingImport = true
        } catch {
            clearPendingImport()
            transferError = error.localizedDescription
        }
    }

    private func performImport(strategy: ClipboardImportStrategy) {
        guard let url = pendingImportURL else { return }
        do {
            let backupURL = try store.importHistory(from: url, strategy: strategy)
            transferMessage = "Imported history. Backup: \(backupURL.lastPathComponent)"
        } catch {
            transferError = error.localizedDescription
        }
        clearPendingImport()
    }

    private func clearPendingImport() {
        pendingImportURL = nil
        pendingImportPreview = nil
        isConfirmingImport = false
    }
}

private struct SettingsErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

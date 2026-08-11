import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @ObservedObject var pasteTargetController: PasteTargetController
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var transferState = SettingsTransferCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingExport = false

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
            isPresented: $transferState.isConfirmingImport,
            titleVisibility: .visible
        ) {
            Button("Merge with Existing History") { performImport(strategy: .merge) }
            Button("Replace Existing History", role: .destructive) { performImport(strategy: .replace) }
            Button("Cancel", role: .cancel) { clearPendingImport() }
        } message: {
            Text(importConfirmationMessage)
        }
    }

    private var generalSettings: some View {
        GeneralSettingsView(store: store, loginItem: loginItem)
    }

    private var privacySettings: some View {
        PrivacySettingsView(store: store, addIgnoredApplication: addIgnoredApplication)
    }

    private var shortcutSettings: some View {
        ShortcutSettingsView(
            store: store,
            hotkeyController: hotkeyController,
            pasteTargetController: pasteTargetController
        )
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
                Text("Exports are unencrypted JSON. Imports are validated, previewed, and backed up before they can change your current history. You can also drop a CopyClip JSON export here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export…") { isConfirmingExport = true }
                    Button("Import…") { chooseImport() }
                }
                .disabled(store.isTransferBusy || transferState.isLoadingDroppedImport)
                if let progress = store.transferProgressText
                    ?? (transferState.isLoadingDroppedImport ? "Reading dropped import…" : nil) {
                    HStack {
                        ProgressView(progress)
                            .controlSize(.small)
                        Spacer()
                        Button("Cancel") {
                            transferState.cancelCurrentTransfer()
                        }
                    }
                }
                if let transferMessage = transferState.message {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let transferError = transferState.error {
                    SettingsErrorText(transferError)
                }
            }
            .onDrop(
                of: [UTType.json.identifier],
                isTargeted: nil,
                perform: handleDroppedImport
            )

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
                    Button("Download Update") { updateChecker.openAvailableUpdate() }
                case let .failed(message):
                    SettingsErrorText(message)
                    Button("Try Again") { updateChecker.check() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var importConfirmationTitle: String {
        guard let preview = transferState.pendingImportPlan?.artifact.preview else {
            return "Import Clipboard History?"
        }
        let clipWord = preview.itemCount == 1 ? "clip" : "clips"
        return "Import \(preview.itemCount) \(clipWord) (\(preview.textCount) text, \(preview.imageCount) images)?"
    }

    private var importConfirmationMessage: String {
        guard let plan = transferState.pendingImportPlan else {
            return "A private backup is created before import."
        }
        let merge = plan.mergeProjection
        let replace = plan.replaceProjection
        return """
        Merge: \(projectionSummary(merge)).
        Replace: \(projectionSummary(replace)).
        A private backup is created before either action.
        """
    }

    private func projectionSummary(_ projection: ClipboardImportProjection) -> String {
        var parts = [
            "\(projection.finalCount) final",
            "\(projection.addedCount) added"
        ]
        if projection.deduplicatedCount > 0 {
            parts.append("\(projection.deduplicatedCount) deduplicated")
        }
        if projection.expiredCount > 0 {
            parts.append("\(projection.expiredCount) expired")
        }
        if projection.overLimitCount > 0 {
            parts.append("\(projection.overLimitCount) over limit")
        }
        if projection.retainedPinnedCount > 0 {
            parts.append("\(projection.retainedPinnedCount) pinned")
        }
        return parts.joined(separator: ", ")
    }

    private func addIgnoredApplication() {
        guard let application = ApplicationPickerPanel.chooseApplication() else { return }
        store.addIgnoredApplication(application)
    }

    private func performExport() {
        transferState.message = nil
        transferState.error = nil
        guard let url = ClipboardHistoryTransferPanel.exportDestinationURL(
            defaultFileName: "CopyClip-Lite-History.json"
        ) else { return }

        transferState.task = Task {
            defer { transferState.task = nil }
            do {
                try await store.exportHistoryAsync(to: url)
                transferState.message = "Exported history to \(url.lastPathComponent)."
            } catch is CancellationError {
                transferState.message = "Export cancelled."
            } catch {
                transferState.error = error.localizedDescription
            }
        }
    }

    private func chooseImport() {
        transferState.message = nil
        transferState.error = nil
        guard let url = ClipboardHistoryTransferPanel.importSourceURL() else { return }

        transferState.task = Task {
            defer { transferState.task = nil }
            do {
                let artifact = try await store.prepareImport(from: url)
                transferState.pendingImportPlan = store.importPlan(for: artifact)
                transferState.isConfirmingImport = true
            } catch is CancellationError {
                clearPendingImport()
                transferState.message = "Import cancelled."
            } catch {
                clearPendingImport()
                transferState.error = error.localizedDescription
            }
        }
    }

    private func handleDroppedImport(_ providers: [NSItemProvider]) -> Bool {
        guard !store.isTransferBusy,
              !transferState.isLoadingDroppedImport,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
              }) else {
            return false
        }

        transferState.message = nil
        transferState.error = nil
        let sourceFileName = provider.suggestedName ?? "Dropped history.json"
        transferState.loadDroppedImport(
            from: provider,
            sourceFileName: sourceFileName,
            store: store
        )
        return true
    }

    private func performImport(strategy: ClipboardImportStrategy) {
        guard let plan = transferState.pendingImportPlan else { return }
        transferState.isConfirmingImport = false
        transferState.task = Task {
            defer { transferState.task = nil }
            do {
                let projection = plan.projection(for: strategy)
                let commit = try await store.importHistory(plan: plan, strategy: strategy)
                transferState.message = importCompletionMessage(
                    projection: projection,
                    actualCount: commit.items.count,
                    backupURL: commit.backupURL
                )
            } catch is CancellationError {
                transferState.message = "Import cancelled before history was changed."
            } catch {
                transferState.error = error.localizedDescription
            }
            clearPendingImport()
        }
    }

    private func clearPendingImport() {
        transferState.pendingImportPlan = nil
        transferState.isConfirmingImport = false
    }

    private func importCompletionMessage(
        projection: ClipboardImportProjection,
        actualCount: Int,
        backupURL: URL
    ) -> String {
        "Imported \(actualCount) clips (\(projection.addedCount) added, "
            + "\(projection.deduplicatedCount) deduplicated, "
            + "\(projection.expiredCount) expired, "
            + "\(projection.overLimitCount) over limit, "
            + "\(projection.retainedPinnedCount) pinned). "
            + "Backup: \(backupURL.lastPathComponent)"
    }
}

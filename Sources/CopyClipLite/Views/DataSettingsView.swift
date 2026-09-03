import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DataSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var transferState = SettingsTransferCoordinator()
    @State private var isConfirmingExport = false
    @State private var isConfirmingUnpinAll = false

    var body: some View {
        Form {
            storageSection
            transferSection
            updatesSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Export Clipboard History?",
            isPresented: $isConfirmingExport,
            titleVisibility: .visible
        ) {
            Button("Export Plaintext JSON") { performExport() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The export contains the full text and images in your history without encryption. Store and share it carefully."
            )
        }
        .confirmationDialog(
            importConfirmationTitle,
            isPresented: $transferState.isConfirmingImport,
            titleVisibility: .visible
        ) {
            Button("Merge with Existing History") { performImport(strategy: .merge) }
            Button("Replace Existing History", role: .destructive) {
                performImport(strategy: .replace)
            }
            Button("Cancel", role: .cancel) { clearPendingImport() }
        } message: {
            Text(importConfirmationMessage)
        }
        .confirmationDialog(
            "Unpin All Clips?",
            isPresented: $isConfirmingUnpinAll,
            titleVisibility: .visible
        ) {
            Button("Unpin All", role: .destructive) { store.unpinAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unpinAllConfirmationMessage)
        }
    }

    private var storageSection: some View {
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
            LabeledContent("Backups") {
                Text(
                    "\(store.backupInventory.count) · "
                        + ByteCountFormatter.string(
                            fromByteCount: store.backupInventory.totalByteCount,
                            countStyle: .file
                        )
                )
            }
            HStack {
                Button("Reveal in Finder") { revealBackups() }
                Button("Delete Backups", role: .destructive) { store.deleteBackups() }
                    .disabled(store.backupInventory.count == 0 || store.isTransferBusy)
            }
            if let errorMessage = store.storageErrorMessage {
                SettingsErrorText(errorMessage)
            }
        }
    }

    private var transferSection: some View {
        Section("Transfer") {
            Text(
                "Exports are unencrypted JSON. Imports are validated, previewed, and backed up before they can change your current history. You can also drop a CopyClip JSON export here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export…") { isConfirmingExport = true }
                Button("Import…") { chooseImport() }
                Button("Unpin All…") { isConfirmingUnpinAll = true }
                    .disabled(pinnedItemCount == 0)
            }
            .disabled(store.isTransferBusy || transferState.isLoadingDroppedImport)
            if let progress = store.transferProgressText
                ?? (transferState.isLoadingDroppedImport ? "Reading dropped import…" : nil)
            {
                HStack {
                    ProgressView(progress).controlSize(.small)
                    Spacer()
                    Button("Cancel") { transferState.cancelCurrentTransfer() }
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
    }

    private var updatesSection: some View {
        Section("Updates") {
            LabeledContent("Installed version", value: updateChecker.currentVersion)
            switch updateChecker.state {
            case .idle:
                Button("Check for Updates") { updateChecker.check() }
            case .checking:
                ProgressView("Checking GitHub Releases…").controlSize(.small)
            case .upToDate:
                Label("CopyClip Lite is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Check Again") { updateChecker.check() }
            case .updateAvailable(let version, _):
                Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                Button("Download Update") { updateChecker.openAvailableUpdate() }
            case .failed(let message):
                SettingsErrorText(message)
                Button("Try Again") { updateChecker.check() }
            }
        }
    }

    private var importConfirmationTitle: String {
        guard let preview = transferState.pendingImportPlan?.artifact.preview else {
            return "Import Clipboard History?"
        }
        let clipWord = preview.itemCount == 1 ? "clip" : "clips"
        return
            "Import \(preview.itemCount) \(clipWord) (\(preview.textCount) text, \(preview.imageCount) images)?"
    }

    private var pinnedItemCount: Int {
        store.items.filter(\.isPinned).count
    }

    private var unpinAllConfirmationMessage: String {
        let pinnedText = pinnedItemCount == 1 ? "1 pinned clip" : "\(pinnedItemCount) pinned clips"
        let deletedCount = store.prospectiveUnpinAllDeletionCount()
        guard deletedCount > 0 else {
            return "This will unpin \(pinnedText). Your retention settings will apply to them."
        }
        let deletedText = deletedCount == 1 ? "1 clip" : "\(deletedCount) clips"
        return "This will unpin \(pinnedText) and permanently delete \(deletedText) under your current retention settings."
    }

    private func revealBackups() {
        if store.backupInventory.urls.isEmpty {
            NSWorkspace.shared.open(store.backupLocation)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(store.backupInventory.urls)
        }
    }

    private var importConfirmationMessage: String {
        guard let plan = transferState.pendingImportPlan else {
            return "A private backup is created before import."
        }
        return """
            Merge: \(projectionSummary(plan.mergeProjection)).
            Replace: \(projectionSummary(plan.replaceProjection)).
            A private backup is created before either action.
            """
    }

    private func projectionSummary(_ projection: ClipboardImportProjection) -> String {
        var parts = ["\(projection.finalCount) final", "\(projection.addedCount) added"]
        if projection.deduplicatedCount > 0 {
            parts.append("\(projection.deduplicatedCount) deduplicated")
        }
        if projection.expiredCount > 0 { parts.append("\(projection.expiredCount) expired") }
        if projection.overLimitCount > 0 { parts.append("\(projection.overLimitCount) over limit") }
        if projection.retainedPinnedCount > 0 {
            parts.append("\(projection.retainedPinnedCount) pinned")
        }
        return parts.joined(separator: ", ")
    }

    private func performExport() {
        transferState.message = nil
        transferState.error = nil
        guard
            let url = ClipboardHistoryTransferPanel.exportDestinationURL(
                defaultFileName: "CopyClip-Lite-History.json"
            )
        else { return }

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
            })
        else {
            return false
        }
        transferState.message = nil
        transferState.error = nil
        transferState.loadDroppedImport(
            from: provider,
            sourceFileName: provider.suggestedName ?? "Dropped history.json",
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

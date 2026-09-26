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
            Self.importConfirmationTitle(for: transferState.pendingImportPlan?.artifact.preview),
            isPresented: $transferState.isConfirmingImport,
            titleVisibility: .visible
        ) {
            Button("Merge with Existing History") { performImport(strategy: .merge) }
            Button("Replace Existing History", role: .destructive) {
                performImport(strategy: .replace)
            }
            Button("Cancel", role: .cancel) { transferState.clearPendingImport() }
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
            if store.imageCleanupPending {
                if store.storageErrorMessage != ClipboardStore.imageCleanupErrorMessage {
                    SettingsErrorText(ClipboardStore.imageCleanupErrorMessage)
                }
                Button("Retry Image Cleanup") {
                    Task { await store.retryImageCleanup() }
                }
                .disabled(store.isTransferBusy)
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
            .disabled(store.isTransferBusy || transferState.isTransferring)
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

    static func importConfirmationTitle(for preview: ClipboardImportPreview?) -> String {
        guard let preview else {
            return "Import Clipboard History?"
        }
        let clipWord = preview.itemCount == 1 ? "clip" : "clips"
        let imageWord = preview.imageCount == 1 ? "image" : "images"
        let fileWord = preview.fileCount == 1 ? "file" : "files"
        let webLinkWord = preview.webLinkCount == 1 ? "web link" : "web links"
        return
            "Import \(preview.itemCount) \(clipWord) (\(preview.textCount) text, "
            + "\(preview.imageCount) \(imageWord), \(preview.fileCount) \(fileWord), "
            + "\(preview.webLinkCount) \(webLinkWord))?"
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
        transferState.clearFeedback()
        guard
            let url = ClipboardHistoryTransferPanel.exportDestinationURL(
                defaultFileName: "CopyClip-Lite-History.json"
            )
        else { return }
        transferState.exportHistory(to: url, store: store)
    }

    private func chooseImport() {
        transferState.clearFeedback()
        guard let url = ClipboardHistoryTransferPanel.importSourceURL() else { return }
        transferState.prepareImport(from: url, store: store)
    }

    private func handleDroppedImport(_ providers: [NSItemProvider]) -> Bool {
        guard !store.isTransferBusy,
            !transferState.isTransferring,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
            })
        else {
            return false
        }
        transferState.loadDroppedImport(
            from: provider,
            sourceFileName: provider.suggestedName ?? "Dropped history.json",
            store: store
        )
        return true
    }

    private func performImport(strategy: ClipboardImportStrategy) {
        transferState.importHistory(strategy: strategy, store: store)
    }
}

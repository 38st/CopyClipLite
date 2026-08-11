import Foundation
import UniformTypeIdentifiers

@MainActor
final class SettingsTransferCoordinator: ObservableObject {
    @Published var message: String?
    @Published var error: String?
    @Published var pendingImportPlan: ClipboardImportPlan?
    @Published var isConfirmingImport = false
    @Published private(set) var isLoadingDroppedImport = false
    var task: Task<Void, Never>?
    private var droppedLoadProgress: Progress?
    private var droppedLoadGeneration: UInt64 = 0

    func loadDroppedImport(
        from provider: NSItemProvider,
        sourceFileName: String,
        store: ClipboardStore
    ) {
        cancelCurrentTransfer()
        droppedLoadGeneration &+= 1
        let generation = droppedLoadGeneration
        isLoadingDroppedImport = true
        droppedLoadProgress = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.json.identifier
        ) { [weak self, store] data, error in
            let loadErrorDescription = error?.localizedDescription
            Task { @MainActor [weak self, store, data, loadErrorDescription, sourceFileName] in
                guard let self,
                      self.droppedLoadGeneration == generation else {
                    return
                }
                self.droppedLoadProgress = nil
                self.receiveDroppedImport(
                    data: data,
                    loadErrorDescription: loadErrorDescription,
                    sourceFileName: sourceFileName,
                    generation: generation,
                    store: store
                )
            }
        }
    }

    func cancelCurrentTransfer() {
        let wasLoadingDroppedImport = isLoadingDroppedImport
        droppedLoadGeneration &+= 1
        droppedLoadProgress?.cancel()
        droppedLoadProgress = nil
        isLoadingDroppedImport = false
        task?.cancel()
        task = nil
        if wasLoadingDroppedImport {
            message = "Import cancelled."
        }
    }

    private func receiveDroppedImport(
        data: Data?,
        loadErrorDescription: String?,
        sourceFileName: String,
        generation: UInt64,
        store: ClipboardStore
    ) {
        if let loadErrorDescription {
            isLoadingDroppedImport = false
            error = loadErrorDescription
            return
        }
        guard let data else {
            isLoadingDroppedImport = false
            error = "The dropped history could not be read."
            return
        }
        guard data.count <= ClipboardStorage.maximumImportBytes else {
            isLoadingDroppedImport = false
            error = ClipboardStorageError.importTooLarge.localizedDescription
            return
        }

        task = Task { @MainActor [weak self, store, data, sourceFileName] in
            guard let self else { return }
            defer {
                if droppedLoadGeneration == generation {
                    task = nil
                    isLoadingDroppedImport = false
                }
            }
            do {
                let artifact = try await store.prepareImport(
                    data: data,
                    sourceFileName: sourceFileName
                )
                try Task.checkCancellation()
                guard droppedLoadGeneration == generation else { return }
                pendingImportPlan = store.importPlan(for: artifact)
                isConfirmingImport = true
            } catch is CancellationError {
                guard droppedLoadGeneration == generation else { return }
                clearPendingImport()
                message = "Import cancelled."
            } catch {
                guard droppedLoadGeneration == generation else { return }
                clearPendingImport()
                self.error = error.localizedDescription
            }
        }
    }

    private func clearPendingImport() {
        pendingImportPlan = nil
        isConfirmingImport = false
    }
}

import Foundation

@MainActor
final class ClipboardStoreTransferCoordinator: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var progressText: String?

    private let transferService: ClipboardTransferService
    private let persistenceCoordinator: ClipboardPersistenceCoordinator

    init(
        transferService: ClipboardTransferService,
        persistenceCoordinator: ClipboardPersistenceCoordinator
    ) {
        self.transferService = transferService
        self.persistenceCoordinator = persistenceCoordinator
    }

    func export(_ items: [ClipboardItem], to url: URL) async throws {
        try await perform(progress: "Preparing export…") {
            try await transferService.export(items, to: url)
        }
    }

    func prepareImport(from url: URL) async throws -> ClipboardImportArtifact {
        try await perform(progress: "Validating import…") {
            try await transferService.prepareImport(from: url)
        }
    }

    func prepareImport(
        data: Data,
        sourceFileName: String
    ) async throws -> ClipboardImportArtifact {
        try await perform(progress: "Validating dropped import…") {
            try await transferService.prepareImport(
                data: data,
                sourceFileName: sourceFileName
            )
        }
    }

    func commitImport(
        plan: ClipboardImportPlan,
        strategy: ClipboardImportStrategy
    ) async throws -> ClipboardImportCommit {
        try await perform(progress: "Applying import…") {
            try await persistenceCoordinator.commitImport(
                currentItems: plan.currentItems,
                candidateItems: plan.candidateItems(for: strategy)
            )
        }
    }

    private func perform<T: Sendable>(
        progress: String,
        operation: () async throws -> T
    ) async throws -> T {
        guard !isBusy else { throw ClipboardStorageError.persistenceFailed }
        isBusy = true
        progressText = progress
        defer {
            isBusy = false
            progressText = nil
        }
        return try await operation()
    }
}

import Foundation

struct ClipboardImportArtifact: Sendable {
    let sourceFileName: String
    let items: [ClipboardItem]
    let preview: ClipboardImportPreview
}

struct ClipboardImportProjection: Sendable, Equatable {
    let strategy: ClipboardImportStrategy
    let sourceItemCount: Int
    let addedCount: Int
    let deduplicatedCount: Int
    let expiredCount: Int
    let overLimitCount: Int
    let retainedPinnedCount: Int
    let finalCount: Int
}

struct ClipboardImportCommit: Sendable {
    let backupURL: URL
    let items: [ClipboardItem]
}

actor ClipboardTransferService {
    private let storage: ClipboardStorage

    init(storage: ClipboardStorage) {
        self.storage = storage
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        try Task.checkCancellation()
        try storage.export(items, to: url)
    }

    func prepareImport(from url: URL) throws -> ClipboardImportArtifact {
        try Task.checkCancellation()
        let items = try storage.importItems(from: url)
        try Task.checkCancellation()
        return ClipboardImportArtifact(
            sourceFileName: url.lastPathComponent,
            items: items,
            preview: ClipboardImportPreview(
                itemCount: items.count,
                textCount: items.filter { $0.contentKind == .text }.count,
                imageCount: items.filter { $0.contentKind == .image }.count
            )
        )
    }

    func commitImport(
        currentItems: [ClipboardItem],
        candidateItems: [ClipboardItem]
    ) throws -> ClipboardImportCommit {
        try Task.checkCancellation()
        try storage.saveValidated(currentItems)
        let backupURL = try storage.backup(currentItems, reason: "pre-import")
        try Task.checkCancellation()
        try storage.saveValidated(candidateItems)
        let loadedItems = try storage.loadResult().get().sorted {
            $0.lastCopiedAt > $1.lastCopiedAt
        }
        return ClipboardImportCommit(backupURL: backupURL, items: loadedItems)
    }
}

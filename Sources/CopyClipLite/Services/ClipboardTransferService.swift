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

struct ClipboardImportPlan: Sendable {
    let artifact: ClipboardImportArtifact
    let currentItems: [ClipboardItem]
    let historyLimit: Int
    let retentionPolicy: ClipboardRetentionPolicy
    let mergeItems: [ClipboardItem]
    let mergeProjection: ClipboardImportProjection
    let replaceItems: [ClipboardItem]
    let replaceProjection: ClipboardImportProjection

    func candidateItems(for strategy: ClipboardImportStrategy) -> [ClipboardItem] {
        switch strategy {
        case .merge:
            mergeItems
        case .replace:
            replaceItems
        }
    }

    func projection(for strategy: ClipboardImportStrategy) -> ClipboardImportProjection {
        switch strategy {
        case .merge:
            mergeProjection
        case .replace:
            replaceProjection
        }
    }
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

    func prepareImport(data: Data, sourceFileName: String) throws -> ClipboardImportArtifact {
        try Task.checkCancellation()
        let items = try storage.importItems(data: data)
        try Task.checkCancellation()
        return ClipboardImportArtifact(
            sourceFileName: sourceFileName,
            items: items,
            preview: ClipboardImportPreview(
                itemCount: items.count,
                textCount: items.filter { $0.contentKind == .text }.count,
                imageCount: items.filter { $0.contentKind == .image }.count
            )
        )
    }

}

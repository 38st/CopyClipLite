import Foundation

enum ClipboardImportStrategy: Sendable, Equatable {
    case merge
    case replace
}

struct ClipboardImportPreview: Sendable, Equatable {
    let itemCount: Int
    let textCount: Int
    let imageCount: Int
    let fileCount: Int
    let webLinkCount: Int

    init(items: [ClipboardItem]) {
        itemCount = items.count
        textCount = items.filter { $0.contentKind == .text }.count
        imageCount = items.filter { $0.contentKind == .image }.count
        fileCount = items.filter { $0.isFileClip }.count
        webLinkCount = items.filter { $0.contentKind == .link && !$0.isFileClip }.count
    }
}

struct ClipboardImportArtifact: Sendable {
    let sourceFileName: String
    let items: [ClipboardItem]
    let preview: ClipboardImportPreview

    init(sourceFileName: String, items: [ClipboardItem]) {
        self.sourceFileName = sourceFileName
        self.items = items
        self.preview = ClipboardImportPreview(items: items)
    }
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

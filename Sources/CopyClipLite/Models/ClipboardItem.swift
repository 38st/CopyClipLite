import Foundation

struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var copyCount: Int

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        copyCount: Int = 1
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = copyCount
    }

    var previewText: String {
        text.copyClipPreview(limit: 160)
    }

    var metadataText: String {
        let copies = copyCount == 1 ? "1 copy" : "\(copyCount) copies"
        return "\(text.copyClipCharacterCountText) · \(copies)"
    }

    var lastCopiedDescription: String {
        lastCopiedAt.copyClipRelativeDescription
    }
}

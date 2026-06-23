import Foundation

struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var copyCount: Int

    private let cachedPreview: String
    private let cachedCharacterCount: Int

    enum CodingKeys: String, CodingKey {
        case id, text, createdAt, lastCopiedAt, isPinned, copyCount
    }

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
        self.cachedPreview = text.copyClipPreview(limit: 160)
        self.cachedCharacterCount = text.count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastCopiedAt = try c.decodeIfPresent(Date.self, forKey: .lastCopiedAt) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        copyCount = try c.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
        cachedPreview = text.copyClipPreview(limit: 160)
        cachedCharacterCount = text.count
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastCopiedAt, forKey: .lastCopiedAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(copyCount, forKey: .copyCount)
    }

    var previewText: String {
        cachedPreview
    }

    var metadataText: String {
        let countText = cachedCharacterCount == 1 ? "1 character" : "\(cachedCharacterCount) characters"
        let copies = copyCount == 1 ? "1 copy" : "\(copyCount) copies"
        return "\(countText) · \(copies)"
    }

    var lastCopiedDescription: String {
        lastCopiedAt.copyClipRelativeDescription
    }
}

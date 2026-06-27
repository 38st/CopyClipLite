import Foundation

enum ClipboardContentKind: String, Codable, Hashable {
    case text
    case image
}

struct ClipboardImagePayload: Codable, Hashable {
    var data: Data?
    var fileName: String?
    var thumbnailData: Data?
    var thumbnailFileName: String?
    var width: Int
    var height: Int
    var byteCount: Int
    var contentHash: String?

    enum CodingKeys: String, CodingKey {
        case data, fileName, thumbnailData, thumbnailFileName, width, height, byteCount, contentHash
    }

    init(
        data: Data? = nil,
        fileName: String? = nil,
        thumbnailData: Data? = nil,
        thumbnailFileName: String? = nil,
        width: Int,
        height: Int,
        byteCount: Int? = nil,
        contentHash: String? = nil
    ) {
        self.data = data
        self.fileName = fileName
        self.thumbnailData = thumbnailData
        self.thumbnailFileName = thumbnailFileName
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.byteCount = byteCount ?? data?.count ?? 0
        self.contentHash = contentHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(Data.self, forKey: .data)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        thumbnailData = try c.decodeIfPresent(Data.self, forKey: .thumbnailData)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        width = max(try c.decodeIfPresent(Int.self, forKey: .width) ?? 0, 0)
        height = max(try c.decodeIfPresent(Int.self, forKey: .height) ?? 0, 0)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? data?.count ?? 0
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        if fileName == nil {
            try c.encodeIfPresent(data, forKey: .data)
        }

        try c.encodeIfPresent(fileName, forKey: .fileName)

        if thumbnailFileName == nil {
            try c.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        }

        try c.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
    }

    var dimensionsText: String {
        guard width > 0, height > 0 else {
            return "Image"
        }

        return "\(width) x \(height)"
    }

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var displayData: Data? {
        thumbnailData ?? data
    }
}

struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var contentKind: ClipboardContentKind
    var image: ClipboardImagePayload?
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var copyCount: Int

    private let cachedPreview: String
    private let cachedCharacterCount: Int

    enum CodingKeys: String, CodingKey {
        case id, text, contentKind, image, createdAt, lastCopiedAt, isPinned, copyCount
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
        self.contentKind = .text
        self.image = nil
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = copyCount
        self.cachedPreview = text.copyClipPreview(limit: 160)
        self.cachedCharacterCount = text.count
    }

    init(
        id: UUID = UUID(),
        text: String = "",
        image: ClipboardImagePayload,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        copyCount: Int = 1
    ) {
        self.id = id
        self.text = text
        self.contentKind = .image
        self.image = image
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = copyCount
        self.cachedPreview = Self.previewText(contentKind: .image, text: text, image: image)
        self.cachedCharacterCount = text.count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        image = try c.decodeIfPresent(ClipboardImagePayload.self, forKey: .image)
        let decodedContentKind = try c.decodeIfPresent(String.self, forKey: .contentKind)
            .flatMap(ClipboardContentKind.init(rawValue:))
        contentKind = Self.normalizedContentKind(decodedContentKind, image: image)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastCopiedAt = try c.decodeIfPresent(Date.self, forKey: .lastCopiedAt) ?? Date()
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        copyCount = try c.decodeIfPresent(Int.self, forKey: .copyCount) ?? 1
        cachedPreview = Self.previewText(contentKind: contentKind, text: text, image: image)
        cachedCharacterCount = text.count
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(contentKind.rawValue, forKey: .contentKind)
        try c.encodeIfPresent(image, forKey: .image)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastCopiedAt, forKey: .lastCopiedAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(copyCount, forKey: .copyCount)
    }

    var previewText: String {
        cachedPreview
    }

    var isImage: Bool {
        contentKind == .image && image != nil
    }

    var searchableText: String {
        switch contentKind {
        case .text:
            text
        case .image:
            "image \(image?.dimensionsText ?? "") \(text)"
        }
    }

    var metadataText: String {
        let copies = copyCount == 1 ? "1 copy" : "\(copyCount) copies"

        switch contentKind {
        case .text:
            let countText = cachedCharacterCount == 1 ? "1 character" : "\(cachedCharacterCount) characters"
            return "\(countText) · \(copies)"
        case .image:
            guard let image else {
                return copies
            }

            return "\(image.dimensionsText) · \(image.byteCountText) · \(copies)"
        }
    }

    var lastCopiedDescription: String {
        lastCopiedAt.copyClipRelativeDescription
    }

    private static func normalizedContentKind(
        _ contentKind: ClipboardContentKind?,
        image: ClipboardImagePayload?
    ) -> ClipboardContentKind {
        if contentKind == .image || image != nil {
            return image == nil ? .text : .image
        }

        return .text
    }

    private static func previewText(
        contentKind: ClipboardContentKind,
        text: String,
        image: ClipboardImagePayload?
    ) -> String {
        switch contentKind {
        case .text:
            return text.copyClipPreview(limit: 160)
        case .image:
            let textPreview = text.copyClipPreview(limit: 96)
            return textPreview.isEmpty ? "Image" : "Image · \(textPreview)"
        }
    }
}

import Foundation

struct ClipboardTransferDocument: Codable {
    static let currentVersion = 1

    let format: String
    let version: Int
    let items: [ClipboardTransferItem]

    init(items: [ClipboardTransferItem]) {
        format = "CopyClipLite"
        version = Self.currentVersion
        self.items = items
    }
}

struct ClipboardTransferImage: Codable {
    let data: Data?
    let fileName: String?
    let thumbnailData: Data?
    let thumbnailFileName: String?
    let width: Int?
    let height: Int?
    let byteCount: Int?
    let contentHash: String?
}

struct ClipboardTransferItem: Codable {
    let id: UUID?
    let text: String?
    let contentKind: String?
    let linkURL: URL?
    let linkTitle: String?
    let image: ClipboardTransferImage?
    let rtfData: Data?
    let htmlData: Data?
    let createdAt: Date?
    let lastCopiedAt: Date?
    let isPinned: Bool?
    let copyCount: Int?
    let sourceApplication: ClipboardSourceApplication?

    init(_ item: ClipboardItem) {
        id = item.id
        text = item.text
        contentKind = item.contentKind.rawValue
        linkURL = item.link?.url
        linkTitle = item.link?.title
        if let image = item.image {
            self.image = ClipboardTransferImage(
                data: image.data,
                fileName: image.fileName,
                thumbnailData: image.thumbnailData,
                thumbnailFileName: image.thumbnailFileName,
                width: image.width,
                height: image.height,
                byteCount: image.byteCount,
                contentHash: image.contentHash
            )
        } else {
            image = nil
        }
        rtfData = item.rtfData
        htmlData = item.htmlData
        createdAt = item.createdAt
        lastCopiedAt = item.lastCopiedAt
        isPinned = item.isPinned
        copyCount = item.copyCount
        sourceApplication = item.sourceApplication
    }
}

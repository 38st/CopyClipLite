import Foundation

struct ClipboardBackupInventory: Equatable, Sendable {
    let urls: [URL]
    let totalByteCount: Int64

    static let empty = ClipboardBackupInventory(urls: [], totalByteCount: 0)

    var count: Int { urls.count }
}

protocol ClipboardHistoryRepository: Sendable {
    var fileURL: URL { get }

    func loadResult() -> Result<[ClipboardItem], ClipboardStorageError>

    @discardableResult
    func saveValidated(_ items: [ClipboardItem]) throws -> [ClipboardItem]

    @discardableResult
    func backup(_ items: [ClipboardItem], reason: String) throws -> URL

    func backupInventory() throws -> ClipboardBackupInventory
    func purgeBackups() throws
}

protocol ClipboardTransferRepository: Sendable {
    func export(_ items: [ClipboardItem], to url: URL) throws
    func importItems(from url: URL) throws -> [ClipboardItem]
    func importItems(data: Data) throws -> [ClipboardItem]
}

protocol ClipboardImageReading: Sendable {
    func imageData(for item: ClipboardItem) -> Data?
}

protocol ClipboardThumbnailRepository: Sendable {
    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult?
}

protocol ClipboardStoreRepository:
    ClipboardHistoryRepository,
    ClipboardTransferRepository,
    ClipboardImageReading,
    ClipboardThumbnailRepository
{}

extension ClipboardStorage: ClipboardStoreRepository {}

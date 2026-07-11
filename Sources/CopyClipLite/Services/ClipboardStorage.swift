import Foundation

enum ClipboardStorageError: LocalizedError, Equatable {
    case unreadableHistory
    case invalidHistory(backupFileName: String?)
    case persistenceFailed
    case importTooLarge
    case tooManyImportedItems
    case duplicateImportedItem
    case invalidImportedItem(String)
    case missingImageData

    var errorDescription: String? {
        switch self {
        case .unreadableHistory:
            return "Clipboard history could not be read. Your existing file was left untouched."
        case let .invalidHistory(backupFileName):
            if let backupFileName {
                return "Clipboard history was damaged and moved to \(backupFileName)."
            }
            return "Clipboard history was damaged and could not be recovered."
        case .persistenceFailed:
            return "Clipboard history could not be saved. Check the Data section in Settings."
        case .importTooLarge:
            return "The history file is too large to import safely."
        case .tooManyImportedItems:
            return "The history file contains too many clips."
        case .duplicateImportedItem:
            return "The history file contains duplicate clip identifiers."
        case let .invalidImportedItem(reason):
            return "The history file contains an invalid clip: \(reason)"
        case .missingImageData:
            return "An image clip is missing its image data."
        }
    }
}

struct ClipboardImportPreview: Equatable {
    let itemCount: Int
    let textCount: Int
    let imageCount: Int
}

struct ClipboardStorage {
    static let maximumImportBytes = 100 * 1024 * 1024
    static let maximumImportedItems = 1_000
    static let maximumImportedTextCharacters = 20_000
    static let maximumImportedImageBytes = 10 * 1024 * 1024

    let fileURL: URL
    let imageDirectoryURL: URL

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()

    init(fileManager: FileManager = .default, appDirectory: URL? = nil) {
        self.fileManager = fileManager

        let appDirectory = appDirectory ?? Self.defaultAppDirectory(fileManager: fileManager)
        self.imageDirectoryURL = appDirectory.appendingPathComponent("Images", isDirectory: true)

        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectoryURL.path)

        fileURL = appDirectory.appendingPathComponent("clipboard-history.json")
    }

    func load() -> [ClipboardItem] {
        (try? loadResult().get()) ?? []
    }

    func loadResult() -> Result<[ClipboardItem], ClipboardStorageError> {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .failure(.unreadableHistory)
        }

        let decoder = JSONDecoder()
        do {
            var items = try decoder.decode([ClipboardItem].self, from: data)
            let wasMigrated = externalizeImageFiles(in: &items)
            hydrateImageThumbnails(in: &items)
            if wasMigrated {
                guard writeHistory(items) else {
                    return .failure(.persistenceFailed)
                }
                removeUnreferencedImageFiles(keeping: items)
            }
            return .success(items)
        } catch {
            let backupURL = backupExistingStore(reason: "invalid")
            return .failure(.invalidHistory(backupFileName: backupURL?.lastPathComponent))
        }
    }

    func save(_ items: [ClipboardItem]) {
        try? saveValidated(items)
    }

    func saveValidated(_ items: [ClipboardItem]) throws {
        lock.lock()
        defer { lock.unlock() }

        var persistedItems = items
        externalizeImageFiles(in: &persistedItems)
        guard writeHistory(persistedItems) else {
            throw ClipboardStorageError.persistenceFailed
        }

        removeUnreferencedImageFiles(keeping: persistedItems)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let image = item.image else {
            return nil
        }

        if let data = image.data {
            return data
        }

        guard let fileName = image.fileName else {
            return nil
        }

        guard let url = safeImageURL(for: fileName) else {
            return nil
        }

        return try? Data(contentsOf: url)
    }

    func thumbnailData(for item: ClipboardItem) -> Data? {
        guard let image = item.image else {
            return nil
        }

        if let data = image.thumbnailData {
            return data
        }

        guard let thumbnailFileName = image.thumbnailFileName else {
            return nil
        }

        guard let url = safeImageURL(for: thumbnailFileName) else {
            return nil
        }

        return try? Data(contentsOf: url)
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let portableItems = try items.map(portableItem)
        let data = try encoder.encode(portableItems)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func importItems(from url: URL) throws -> [ClipboardItem] {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw ClipboardStorageError.invalidImportedItem("the selected item is not a regular file")
        }
        guard (resourceValues.fileSize ?? 0) <= Self.maximumImportBytes else {
            throw ClipboardStorageError.importTooLarge
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumImportBytes else {
            throw ClipboardStorageError.importTooLarge
        }

        var items = try JSONDecoder().decode([ClipboardItem].self, from: data)
        try validateImportedItems(items)
        let latestAllowedDate = Date().addingTimeInterval(5 * 60)
        for index in items.indices {
            items[index].createdAt = min(items[index].createdAt, latestAllowedDate)
            items[index].lastCopiedAt = min(items[index].lastCopiedAt, latestAllowedDate)
            if var image = items[index].image, let imageData = image.data {
                image.byteCount = imageData.count
                image.contentHash = ClipboardImageProcessor.contentHash(for: imageData)
                items[index].image = image
            }
        }
        return items
    }

    func importPreview(from url: URL) throws -> ClipboardImportPreview {
        let items = try importItems(from: url)
        return ClipboardImportPreview(
            itemCount: items.count,
            textCount: items.filter { $0.contentKind == .text }.count,
            imageCount: items.filter { $0.contentKind == .image }.count
        )
    }

    @discardableResult
    func backup(_ items: [ClipboardItem], reason: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension(
                "\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
            )
        try export(items, to: backupURL)
        return backupURL
    }

    @discardableResult
    private func writeHistory(_ items: [ClipboardItem]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        guard let data = try? encoder.encode(items) else {
            return false
        }

        guard (try? data.write(to: fileURL, options: [.atomic])) != nil else {
            return false
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return true
    }

    @discardableResult
    private func externalizeImageFiles(in items: inout [ClipboardItem]) -> Bool {
        var didChange = false

        for index in items.indices {
            guard var image = items[index].image else {
                continue
            }

            if let data = image.data {
                let fileName = safeFileName(image.fileName) ?? "\(items[index].id.uuidString).png"
                guard let fileURL = safeImageURL(for: fileName) else { continue }

                if writeImageData(data, to: fileURL) {
                    image.fileName = fileName
                    image.data = nil
                    didChange = true
                }
            }

            if let thumbnailData = image.thumbnailData {
                let fileName = safeFileName(image.thumbnailFileName) ?? "\(items[index].id.uuidString)-thumb.png"
                guard let fileURL = safeImageURL(for: fileName) else { continue }

                if writeImageData(thumbnailData, to: fileURL) {
                    image.thumbnailFileName = fileName
                    image.thumbnailData = nil
                    didChange = true
                }
            }

            items[index].image = image
        }

        return didChange
    }

    private func hydrateImageThumbnails(in items: inout [ClipboardItem]) {
        for index in items.indices {
            guard var image = items[index].image else {
                continue
            }

            if image.byteCount == 0,
               let fileName = image.fileName,
               let imageURL = safeImageURL(for: fileName),
               let attributes = try? fileManager.attributesOfItem(
                    atPath: imageURL.path
               ),
               let size = attributes[.size] as? NSNumber {
                image.byteCount = size.intValue
            }

            items[index].image = image
        }
    }

    private func portableItem(_ item: ClipboardItem) throws -> ClipboardItem {
        guard var image = item.image else {
            return item
        }

        var portable = item
        image.data = image.data ?? imageData(for: item)
        guard image.data != nil else {
            throw ClipboardStorageError.missingImageData
        }

        if image.thumbnailData == nil,
           let thumbnailFileName = image.thumbnailFileName,
           let thumbnailURL = safeImageURL(for: thumbnailFileName) {
            image.thumbnailData = try? Data(contentsOf: thumbnailURL)
        }

        image.fileName = nil
        image.thumbnailFileName = nil
        portable.image = image
        return portable
    }

    private func writeImageData(_ data: Data, to url: URL) -> Bool {
        guard (try? data.write(to: url, options: [.atomic])) != nil else {
            return false
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    func removeUnreferencedImageFiles(keeping items: [ClipboardItem]) {
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: imageDirectoryURL.path) else {
            return
        }

        let referencedFileNames = Set(
            items.flatMap { item in
                [item.image?.fileName, item.image?.thumbnailFileName].compactMap { $0 }
            }
        )

        for fileName in fileNames where !referencedFileNames.contains(fileName) {
            try? fileManager.removeItem(at: imageDirectoryURL.appendingPathComponent(fileName))
        }
    }

    @discardableResult
    private func backupExistingStore(reason: String) -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json")

        guard (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil else {
            return nil
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }

    private func validateImportedItems(_ items: [ClipboardItem]) throws {
        guard items.count <= Self.maximumImportedItems else {
            throw ClipboardStorageError.tooManyImportedItems
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw ClipboardStorageError.duplicateImportedItem
        }

        for item in items {
            guard item.text.count <= Self.maximumImportedTextCharacters else {
                throw ClipboardStorageError.invalidImportedItem("text exceeds 20,000 characters")
            }
            guard (1...1_000_000).contains(item.copyCount) else {
                throw ClipboardStorageError.invalidImportedItem("copy count is outside the supported range")
            }
            guard item.rtfData?.count ?? 0 <= Self.maximumImportedImageBytes,
                  item.htmlData?.count ?? 0 <= Self.maximumImportedImageBytes else {
                throw ClipboardStorageError.invalidImportedItem("rich text data is too large")
            }

            if let image = item.image {
                guard image.fileName == nil, image.thumbnailFileName == nil else {
                    throw ClipboardStorageError.invalidImportedItem("external image paths are not allowed")
                }
                guard let data = image.data, !data.isEmpty else {
                    throw ClipboardStorageError.missingImageData
                }
                guard data.count <= Self.maximumImportedImageBytes,
                      image.thumbnailData?.count ?? 0 <= Self.maximumImportedImageBytes else {
                    throw ClipboardStorageError.invalidImportedItem("image data is too large")
                }
                guard image.width >= 0, image.height >= 0,
                      image.width <= 16_384, image.height <= 16_384 else {
                    throw ClipboardStorageError.invalidImportedItem("image dimensions are invalid")
                }
            }
        }
    }

    private func safeFileName(_ fileName: String?) -> String? {
        guard let fileName, safeImageURL(for: fileName) != nil else {
            return nil
        }
        return fileName
    }

    private func safeImageURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return nil
        }

        let baseURL = imageDirectoryURL.standardizedFileURL
        let candidateURL = baseURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard candidateURL.deletingLastPathComponent() == baseURL else {
            return nil
        }
        return candidateURL
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func defaultAppDirectory(fileManager: FileManager) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser

        return supportDirectory.appendingPathComponent("CopyClipLite", isDirectory: true)
    }
}

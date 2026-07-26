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
    case incompatibleExport(String)
    case unsupportedTransferVersion(Int)

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
        case let .incompatibleExport(reason):
            return "Clipboard history cannot be exported: \(reason)"
        case let .unsupportedTransferVersion(version):
            return "This history uses unsupported transfer format version \(version)."
        }
    }
}

struct ClipboardImportPreview: Equatable {
    let itemCount: Int
    let textCount: Int
    let imageCount: Int
}

private struct ClipboardTransferDocument: Codable {
    static let currentVersion = 1

    let format: String
    let version: Int
    let items: [ClipboardTransferItem]

    init(items: [ClipboardTransferItem]) {
        self.format = "CopyClipLite"
        self.version = Self.currentVersion
        self.items = items
    }
}

private struct ClipboardTransferImage: Codable {
    let data: Data?
    let fileName: String?
    let thumbnailData: Data?
    let thumbnailFileName: String?
    let width: Int?
    let height: Int?
    let byteCount: Int?
    let contentHash: String?
}

private struct ClipboardTransferItem: Codable {
    let id: UUID?
    let text: String?
    let contentKind: String?
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

enum ClipboardStorageFaultPoint {
    case imageWrite
    case manifestWrite
}

struct ClipboardStorage: @unchecked Sendable {
    static let maximumImportBytes = 100 * 1024 * 1024
    static let maximumImportedItems = 1_000
    static let maximumImportedTextCharacters = 20_000
    static let maximumImportedImageBytes = 10 * 1024 * 1024
    static let maximumImportedRichTextBytes = 10 * 1024 * 1024

    let fileURL: URL
    let imageDirectoryURL: URL

    private let fileManager: FileManager
    private let faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    private let lock = NSRecursiveLock()

    init(
        fileManager: FileManager = .default,
        appDirectory: URL? = nil,
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector

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
        var items: [ClipboardItem]
        do {
            items = try decoder.decode([ClipboardItem].self, from: data)
        } catch {
            let backupURL = backupExistingStore(reason: "invalid")
            return .failure(.invalidHistory(backupFileName: backupURL?.lastPathComponent))
        }

        do {
            let wasExternalized = try externalizeImageFiles(in: &items)
            let wasHydrated = hydrateImageMetadata(in: &items)
            if wasExternalized || wasHydrated {
                try writeHistory(items)
                removeUnreferencedImageFiles(keeping: items)
            }
            return .success(items)
        } catch {
            return .failure(.persistenceFailed)
        }
    }

    func save(_ items: [ClipboardItem]) {
        _ = try? saveValidated(items)
    }

    @discardableResult
    func saveValidated(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }

        var persistedItems = items
        do {
            try externalizeImageFiles(in: &persistedItems)
            try writeHistory(persistedItems)
        } catch {
            throw ClipboardStorageError.persistenceFailed
        }

        removeUnreferencedImageFiles(keeping: persistedItems)
        return persistedItems
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

        guard items.count <= Self.maximumImportedItems else {
            throw ClipboardStorageError.incompatibleExport(
                "the same version accepts at most \(Self.maximumImportedItems) clips"
            )
        }
        let portableItems = try items.map(portableItem)
        try validateDomainItemsForExport(portableItems)
        let document = ClipboardTransferDocument(items: portableItems.map(ClipboardTransferItem.init))
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumImportBytes else {
            throw ClipboardStorageError.incompatibleExport(
                "the encoded file would exceed \(ByteCountFormatter.string(fromByteCount: Int64(Self.maximumImportBytes), countStyle: .file))"
            )
        }
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

        let decoder = JSONDecoder()
        let transferItems: [ClipboardTransferItem]
        let isCurrentFormat: Bool
        if let document = try? decoder.decode(ClipboardTransferDocument.self, from: data) {
            guard document.format == "CopyClipLite" else {
                throw ClipboardStorageError.invalidImportedItem("the transfer format identifier is invalid")
            }
            guard document.version == ClipboardTransferDocument.currentVersion else {
                throw ClipboardStorageError.unsupportedTransferVersion(document.version)
            }
            transferItems = document.items
            isCurrentFormat = true
        } else {
            transferItems = try decoder.decode([ClipboardTransferItem].self, from: data)
            isCurrentFormat = false
        }

        var items = try transferItems.map {
            try domainItem(from: $0, isCurrentFormat: isCurrentFormat)
        }
        try validateImportedItems(items)
        let latestAllowedDate = Date().addingTimeInterval(5 * 60)
        for index in items.indices {
            items[index].createdAt = min(items[index].createdAt, latestAllowedDate)
            items[index].lastCopiedAt = min(items[index].lastCopiedAt, latestAllowedDate)
            if var image = items[index].image, let imageData = image.data {
                do {
                    image = try ClipboardImageProcessor.process(
                        ClipboardImageCandidate(data: imageData, isPNG: true)
                    )
                } catch {
                    throw ClipboardStorageError.invalidImportedItem(
                        error.localizedDescription
                    )
                }
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

    private func writeHistory(_ items: [ClipboardItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let data = try encoder.encode(items)
        try faultInjector?(.manifestWrite)
        try data.write(to: fileURL, options: [.atomic])

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    @discardableResult
    private func externalizeImageFiles(in items: inout [ClipboardItem]) throws -> Bool {
        var didChange = false

        for index in items.indices {
            guard var image = items[index].image else {
                continue
            }

            if let data = image.data {
                let contentHash = ClipboardImageProcessor.contentHash(for: data)
                let fileName = "\(items[index].id.uuidString)-\(contentHash).png"
                guard let fileURL = safeImageURL(for: fileName) else {
                    throw ClipboardStorageError.persistenceFailed
                }

                try writeImageData(data, to: fileURL)
                image.fileName = fileName
                image.data = nil
                image.contentHash = contentHash
                didChange = true
            }

            if let thumbnailData = image.thumbnailData {
                let thumbnailHash = ClipboardImageProcessor.contentHash(for: thumbnailData)
                let fileName = "\(items[index].id.uuidString)-thumb-\(thumbnailHash).png"
                guard let fileURL = safeImageURL(for: fileName) else {
                    throw ClipboardStorageError.persistenceFailed
                }

                try writeImageData(thumbnailData, to: fileURL)
                image.thumbnailFileName = fileName
                image.thumbnailData = nil
                didChange = true
            }

            items[index].image = image
        }

        return didChange
    }

    @discardableResult
    private func hydrateImageMetadata(in items: inout [ClipboardItem]) -> Bool {
        var didChange = false

        for index in items.indices {
            guard var image = items[index].image else {
                continue
            }

            if let fileName = image.fileName,
               let imageURL = safeImageURL(for: fileName),
               let fullData = try? Data(contentsOf: imageURL) {
                if image.byteCount == 0 {
                    image.byteCount = fullData.count
                    didChange = true
                }
                if image.contentHash == nil {
                    image.contentHash = ClipboardImageProcessor.contentHash(for: fullData)
                    didChange = true
                }
                let thumbnailIsUsable: Bool
                if let thumbnailData = image.thumbnailData {
                    thumbnailIsUsable = ClipboardImageProcessor.isDecodableImage(thumbnailData)
                } else if let thumbnailFileName = image.thumbnailFileName,
                          let thumbnailURL = safeImageURL(for: thumbnailFileName),
                          let thumbnailData = try? Data(contentsOf: thumbnailURL) {
                    thumbnailIsUsable = ClipboardImageProcessor.isDecodableImage(thumbnailData)
                } else {
                    thumbnailIsUsable = false
                }

                if !thumbnailIsUsable,
                   let repaired = try? ClipboardImageProcessor.process(
                    ClipboardImageCandidate(data: fullData, isPNG: true)
                   ),
                   let thumbnailData = repaired.thumbnailData {
                    let thumbnailHash = ClipboardImageProcessor.contentHash(for: thumbnailData)
                    let fileName = "\(items[index].id.uuidString)-thumb-\(thumbnailHash).png"
                    if let thumbnailURL = safeImageURL(for: fileName),
                       (try? writeImageData(thumbnailData, to: thumbnailURL)) != nil {
                        image.thumbnailFileName = fileName
                        image.thumbnailData = nil
                        didChange = true
                    }
                }
            }

            items[index].image = image
        }

        return didChange
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

    private func writeImageData(_ data: Data, to url: URL) throws {
        try faultInjector?(.imageWrite)
        try data.write(to: url, options: [.atomic])

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeUnreferencedImageFiles(keeping items: [ClipboardItem]) {
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

        let recoveryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "Recovery-\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let backupURL = recoveryURL.appendingPathComponent(fileURL.lastPathComponent)

        do {
            try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryURL.path)
            try fileManager.moveItem(at: fileURL, to: backupURL)
            if fileManager.fileExists(atPath: imageDirectoryURL.path) {
                try fileManager.moveItem(
                    at: imageDirectoryURL,
                    to: recoveryURL.appendingPathComponent("Images", isDirectory: true)
                )
            }
            try fileManager.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageDirectoryURL.path)
        } catch {
            let quarantinedImagesURL = recoveryURL.appendingPathComponent("Images", isDirectory: true)
            if fileManager.fileExists(atPath: quarantinedImagesURL.path),
               !fileManager.fileExists(atPath: imageDirectoryURL.path) {
                try? fileManager.moveItem(at: quarantinedImagesURL, to: imageDirectoryURL)
            }
            if fileManager.fileExists(atPath: backupURL.path),
               !fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.moveItem(at: backupURL, to: fileURL)
            }
            try? fileManager.removeItem(at: recoveryURL)
            return nil
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return recoveryURL
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
            guard item.rtfData?.count ?? 0 <= Self.maximumImportedRichTextBytes,
                  item.htmlData?.count ?? 0 <= Self.maximumImportedRichTextBytes else {
                throw ClipboardStorageError.invalidImportedItem("rich text data is too large")
            }

            switch item.contentKind {
            case .text:
                guard item.image == nil else {
                    throw ClipboardStorageError.invalidImportedItem("a text clip contains image data")
                }
                guard item.text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
                    throw ClipboardStorageError.invalidImportedItem("a text clip is blank")
                }
            case .image:
                guard let image = item.image else {
                    throw ClipboardStorageError.missingImageData
                }
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
            }
        }
    }

    private func validateDomainItemsForExport(_ items: [ClipboardItem]) throws {
        do {
            try validateImportedItems(items)
        } catch let error as ClipboardStorageError {
            throw ClipboardStorageError.incompatibleExport(error.localizedDescription)
        }
    }

    private func domainItem(
        from transfer: ClipboardTransferItem,
        isCurrentFormat: Bool
    ) throws -> ClipboardItem {
        let kind: ClipboardContentKind
        if let rawKind = transfer.contentKind {
            guard let decodedKind = ClipboardContentKind(rawValue: rawKind) else {
                throw ClipboardStorageError.invalidImportedItem("unknown content kind “\(rawKind)”")
            }
            kind = decodedKind
        } else {
            kind = transfer.image == nil ? .text : .image
        }

        let now = Date()
        let id = transfer.id ?? UUID()
        let text = transfer.text ?? ""
        let createdAt = transfer.createdAt ?? now
        let lastCopiedAt = transfer.lastCopiedAt ?? createdAt
        let copyCount = transfer.copyCount ?? 1

        switch kind {
        case .text:
            guard transfer.image == nil else {
                throw ClipboardStorageError.invalidImportedItem("a text clip contains image data")
            }
            return ClipboardItem(
                id: id,
                text: text,
                rtfData: transfer.rtfData,
                htmlData: transfer.htmlData,
                createdAt: createdAt,
                lastCopiedAt: lastCopiedAt,
                isPinned: transfer.isPinned ?? false,
                copyCount: copyCount,
                sourceApplication: transfer.sourceApplication
            )
        case .image:
            guard let transferImage = transfer.image else {
                throw ClipboardStorageError.missingImageData
            }
            guard transferImage.fileName == nil, transferImage.thumbnailFileName == nil else {
                throw ClipboardStorageError.invalidImportedItem("external image paths are not allowed")
            }
            guard let data = transferImage.data, !data.isEmpty else {
                throw ClipboardStorageError.missingImageData
            }
            if isCurrentFormat {
                guard let width = transferImage.width, width > 0,
                      let height = transferImage.height, height > 0 else {
                    throw ClipboardStorageError.invalidImportedItem(
                        "image dimensions must be positive"
                    )
                }
            }
            let image = ClipboardImagePayload(
                data: data,
                thumbnailData: transferImage.thumbnailData,
                width: transferImage.width ?? 0,
                height: transferImage.height ?? 0,
                byteCount: transferImage.byteCount,
                contentHash: transferImage.contentHash
            )
            return ClipboardItem(
                id: id,
                text: text,
                image: image,
                createdAt: createdAt,
                lastCopiedAt: lastCopiedAt,
                isPinned: transfer.isPinned ?? false,
                copyCount: copyCount,
                sourceApplication: transfer.sourceApplication
            )
        }
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

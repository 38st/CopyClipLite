import Darwin
import Foundation

enum ClipboardStorageError: LocalizedError, Equatable {
    case unreadableHistory
    case invalidHistory(backupFileName: String?)
    case persistenceFailed
    case importTooLarge
    case tooManyImportedItems
    case duplicateImportedItem
    case invalidImportedItem(String)
    case importPlanExpired
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
        case .importPlanExpired:
            return "Clipboard history or import settings changed. Review the import again before applying it."
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

struct ClipboardThumbnailResult: Sendable {
    let data: Data
    let fileName: String
}

enum ClipboardStorageFaultPoint: Equatable {
    /// Immediately before writing a full-image or thumbnail sidecar.
    case imageWrite
    /// Immediately after a sidecar has been atomically written.
    case imageWriteCompleted
    /// Immediately before staging the next manifest.
    case manifestWrite
    /// After the complete manifest is staged, immediately before its atomic commit.
    case manifestWriteCompleted
}

struct ClipboardStorage: @unchecked Sendable {
    static let maximumImportBytes = 100 * 1024 * 1024
    static let maximumImportedItems = 1_000
    static let maximumImportedTextCharacters = 20_000
    static let maximumImportedImageBytes = 10 * 1024 * 1024
    static let maximumImportedRichTextBytes = 10 * 1024 * 1024
    private static let maximumRetainedBackups = 5

    let fileURL: URL
    let imageDirectoryURL: URL

    private let fileManager: FileManager
    private let faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    private let imageSidecars: ClipboardImageSidecarStore
    private let lock = NSRecursiveLock()
    private let loadProtection = ClipboardStorageLoadProtection()

    init(
        fileManager: FileManager = .default,
        appDirectory: URL? = nil,
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)? = nil
    ) {
        let appDirectory = appDirectory ?? Self.defaultAppDirectory(fileManager: fileManager)
        let imageDirectoryURL = appDirectory.appendingPathComponent("Images", isDirectory: true)
        self.fileManager = fileManager
        self.faultInjector = faultInjector
        self.imageDirectoryURL = imageDirectoryURL
        self.imageSidecars = ClipboardImageSidecarStore(
            directoryURL: imageDirectoryURL,
            fileManager: fileManager,
            faultInjector: faultInjector
        )

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
            loadProtection.allowWrites()
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            loadProtection.protectWrites()
            return .failure(.unreadableHistory)
        }

        let decoder = JSONDecoder()
        var items: [ClipboardItem]
        do {
            items = try decoder.decode([ClipboardItem].self, from: data)
            guard Self.hasUniqueIdentifiers(items) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Clipboard history contains duplicate identifiers."
                    )
                )
            }
        } catch {
            let backupURL = backupExistingStore(reason: "invalid")
            if backupURL == nil {
                loadProtection.protectWrites()
            } else {
                loadProtection.allowWrites()
            }
            return .failure(.invalidHistory(backupFileName: backupURL?.lastPathComponent))
        }

        var newlyCreatedFiles = Set<URL>()
        do {
            let wasExternalized = try imageSidecars.externalizeImages(
                in: &items,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            let wasHydrated = imageSidecars.hydrateMetadata(in: &items)
            if wasExternalized || wasHydrated || Self.requiresNormalization(data) {
                try writeHistory(items)
                imageSidecars.removeUnreferencedFiles(keeping: items)
            }
            loadProtection.allowWrites()
            return .success(items)
        } catch {
            imageSidecars.removeFiles(newlyCreatedFiles)
            loadProtection.protectWrites()
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

        guard loadProtection.writesAreAllowed,
              Self.hasUniqueIdentifiers(items) else {
            throw ClipboardStorageError.persistenceFailed
        }

        var persistedItems = items
        var newlyCreatedFiles = Set<URL>()
        do {
            try imageSidecars.externalizeImages(
                in: &persistedItems,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            try writeHistory(persistedItems)
        } catch {
            imageSidecars.removeFiles(newlyCreatedFiles)
            throw ClipboardStorageError.persistenceFailed
        }

        imageSidecars.removeUnreferencedFiles(keeping: persistedItems)
        return persistedItems
    }

    func imageData(for item: ClipboardItem) -> Data? {
        imageSidecars.imageData(for: item)
    }

    func thumbnailData(for item: ClipboardItem) -> Data? {
        imageSidecars.thumbnailData(for: item)
    }

    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult? {
        lock.lock()
        defer { lock.unlock() }

        return imageSidecars.thumbnailDataRepairingIfNeeded(for: item)
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        guard items.count <= Self.maximumImportedItems else {
            throw ClipboardStorageError.incompatibleExport(
                ClipboardTransferCodec.itemLimitExceededReason(itemCount: items.count)
            )
        }
        let portableItems = try items.map(imageSidecars.portableItem)
        let data = try ClipboardTransferCodec.encode(portableItems)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // Deliberately unlocked. This reads a caller-supplied file outside the store and
    // decodes it; it never touches the history manifest or the image sidecars. Taking
    // the store lock here would make an import wait on an in-flight save, which
    // deadlocks the pending-persist-during-import path.
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

        return try importItems(data: data)
    }

    func importItems(data: Data) throws -> [ClipboardItem] {
        try ClipboardTransferCodec.decode(data)
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
        let portableItems = try items.map(imageSidecars.portableItem)
        let document = ClipboardTransferDocument(
            items: portableItems.map(ClipboardTransferItem.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: backupURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        try removeExcessBackups(
            matching: Self.isPreImportBackup,
            keeping: Self.maximumRetainedBackups
        )
        return backupURL
    }

    func backupInventory() throws -> ClipboardBackupInventory {
        lock.lock()
        defer { lock.unlock() }

        let urls = try backupURLs()
        return ClipboardBackupInventory(
            urls: urls,
            totalByteCount: try urls.reduce(0) { try $0 + byteCount(of: $1) }
        )
    }

    func purgeBackups() throws {
        lock.lock()
        defer { lock.unlock() }

        for url in try backupURLs() {
            try fileManager.removeItem(at: url)
        }
    }

    private func writeHistory(_ items: [ClipboardItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let data = try encoder.encode(items)
        try faultInjector?(.manifestWrite)
        let stagedURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".clipboard-history-\(UUID().uuidString).pending")
        defer { try? fileManager.removeItem(at: stagedURL) }
        try data.write(to: stagedURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        try faultInjector?(.manifestWriteCompleted)

        guard rename(stagedURL.path, fileURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
        try? removeExcessBackups(
            matching: Self.isRecoveryBackup,
            keeping: Self.maximumRetainedBackups
        )
        return recoveryURL
    }

    private func backupURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ).filter { url in
            Self.isPreImportBackup(url) || Self.isRecoveryBackup(url)
        }
    }

    private func removeExcessBackups(
        matching predicate: (URL) -> Bool,
        keeping retainedCount: Int
    ) throws {
        let matchingURLs = try backupURLs().filter(predicate)
        let sortedURLs = try matchingURLs.sorted { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }
        for url in sortedURLs.dropFirst(retainedCount) {
            try fileManager.removeItem(at: url)
        }
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            let childValues = try childURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            if childValues.isRegularFile == true {
                total += Int64(childValues.fileSize ?? 0)
            }
        }
        return total
    }

    private static func isPreImportBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("clipboard-history.pre-import-"),
              name.hasSuffix(".json") else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isRecoveryBackup(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix("Recovery-") else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func hasUniqueIdentifiers(_ items: [ClipboardItem]) -> Bool {
        Set(items.map(\.id)).count == items.count
    }

    private static func requiresNormalization(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let records = root as? [[String: Any]] else {
            return false
        }
        let requiredKeys: Set<String> = [
            "id",
            "text",
            "contentKind",
            "createdAt",
            "lastCopiedAt",
            "isPinned",
            "copyCount",
        ]
        return records.contains { !requiredKeys.isSubset(of: Set($0.keys)) }
    }

    private static func defaultAppDirectory(fileManager: FileManager) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser

        return supportDirectory.appendingPathComponent("CopyClipLite", isDirectory: true)
    }
}

private final class ClipboardStorageLoadProtection: @unchecked Sendable {
    private let lock = NSLock()
    private var isProtected = false

    var writesAreAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isProtected
    }

    func protectWrites() {
        lock.lock()
        isProtected = true
        lock.unlock()
    }

    func allowWrites() {
        lock.lock()
        isProtected = false
        lock.unlock()
    }
}

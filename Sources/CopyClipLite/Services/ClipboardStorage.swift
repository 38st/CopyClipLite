import Foundation

struct ClipboardStorage {
    let fileURL: URL
    let imageDirectoryURL: URL

    private let fileManager: FileManager

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
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return []
        }

        let decoder = JSONDecoder()
        do {
            var items = try decoder.decode([ClipboardItem].self, from: data)
            let wasMigrated = externalizeImageFiles(in: &items)
            hydrateImageThumbnails(in: &items)
            if wasMigrated {
                writeHistory(items)
                removeUnreferencedImageFiles(keeping: items)
            }
            return items
        } catch {
            backupExistingStore(reason: "invalid")
            return []
        }
    }

    func save(_ items: [ClipboardItem]) {
        var persistedItems = items
        let didExternalize = externalizeImageFiles(in: &persistedItems)
        guard writeHistory(persistedItems) else {
            return
        }

        if didExternalize {
            removeUnreferencedImageFiles(keeping: persistedItems)
        }
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

        return try? Data(contentsOf: imageDirectoryURL.appendingPathComponent(fileName))
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

        return try? Data(contentsOf: imageDirectoryURL.appendingPathComponent(thumbnailFileName))
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let portableItems = items.map(portableItem)
        let data = try encoder.encode(portableItems)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func importItems(from url: URL) throws -> [ClipboardItem] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ClipboardItem].self, from: data)
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
                let fileName = image.fileName ?? "\(items[index].id.uuidString).png"
                let fileURL = imageDirectoryURL.appendingPathComponent(fileName)

                if writeImageData(data, to: fileURL) {
                    image.fileName = fileName
                    image.data = nil
                    didChange = true
                }
            }

            if let thumbnailData = image.thumbnailData {
                let fileName = image.thumbnailFileName ?? "\(items[index].id.uuidString)-thumb.png"
                let fileURL = imageDirectoryURL.appendingPathComponent(fileName)

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
               let attributes = try? fileManager.attributesOfItem(
                    atPath: imageDirectoryURL.appendingPathComponent(fileName).path
               ),
               let size = attributes[.size] as? NSNumber {
                image.byteCount = size.intValue
            }

            items[index].image = image
        }
    }

    private func portableItem(_ item: ClipboardItem) -> ClipboardItem {
        guard var image = item.image else {
            return item
        }

        var portable = item
        image.data = image.data ?? imageData(for: item)

        if image.thumbnailData == nil,
           let thumbnailFileName = image.thumbnailFileName {
            image.thumbnailData = try? Data(
                contentsOf: imageDirectoryURL.appendingPathComponent(thumbnailFileName)
            )
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

    private func backupExistingStore(reason: String) {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json")

        try? fileManager.moveItem(at: fileURL, to: backupURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
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

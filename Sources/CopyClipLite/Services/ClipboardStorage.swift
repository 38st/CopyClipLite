import Foundation

struct ClipboardStorage {
    let fileURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default, appDirectory: URL? = nil) {
        self.fileManager = fileManager

        let appDirectory = appDirectory ?? Self.defaultAppDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)

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
            return try decoder.decode([ClipboardItem].self, from: data)
        } catch {
            backupExistingStore(reason: "invalid")
            return []
        }
    }

    func save(_ items: [ClipboardItem]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        guard let data = try? encoder.encode(items) else {
            return
        }

        guard (try? data.write(to: fileURL, options: [.atomic])) != nil else {
            return
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func backupExistingStore(reason: String) {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("\(reason)-\(Self.backupTimestampFormatter.string(from: Date())).json")

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

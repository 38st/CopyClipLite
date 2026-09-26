import Darwin
import Foundation

actor ClipboardTransferService {
    private let storage: any ClipboardTransferRepository

    init(storage: any ClipboardTransferRepository) {
        self.storage = storage
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        try Task.checkCancellation()
        // Resolved inside the actor rather than stored: FileManager is not Sendable,
        // so holding one as actor state means passing a non-Sendable value across an
        // isolation boundary at every call site.
        let fileManager = FileManager.default
        let stagingDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingDirectory.path
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        let stagedURL = stagingDirectory.appendingPathComponent("history.pending")

        try storage.export(items, to: stagedURL)
        try Task.checkCancellation()
        guard rename(stagedURL.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func prepareImport(from url: URL) throws -> ClipboardImportArtifact {
        try Task.checkCancellation()
        let items = try storage.importItems(from: url)
        try Task.checkCancellation()
        return ClipboardImportArtifact(
            sourceFileName: url.lastPathComponent,
            items: items
        )
    }

    func prepareImport(data: Data, sourceFileName: String) throws -> ClipboardImportArtifact {
        try Task.checkCancellation()
        let items = try storage.importItems(data: data)
        try Task.checkCancellation()
        return ClipboardImportArtifact(
            sourceFileName: sourceFileName,
            items: items
        )
    }
}

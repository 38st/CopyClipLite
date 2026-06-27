import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipboardHistoryTransferPanel {
    static func exportDestinationURL(defaultFileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFileName
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func importSourceURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
enum ApplicationPickerPanel {
    static func chooseApplication() -> ClipboardSourceApplication? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let name = displayName ?? bundleName ?? url.deletingPathExtension().lastPathComponent

        return ClipboardSourceApplication(bundleIdentifier: bundleIdentifier, name: name)
    }
}

import AppKit
import Foundation

struct ClipboardSourceApplication: Codable, Hashable, Identifiable {
    var bundleIdentifier: String
    var name: String

    var id: String {
        bundleIdentifier
    }

    init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    init?(runningApplication: NSRunningApplication?) {
        guard let runningApplication,
              let bundleIdentifier = runningApplication.bundleIdentifier else {
            return nil
        }

        self.bundleIdentifier = bundleIdentifier
        self.name = runningApplication.localizedName ?? bundleIdentifier
    }

    static func frontmost() -> ClipboardSourceApplication? {
        ClipboardSourceApplication(runningApplication: NSWorkspace.shared.frontmostApplication)
    }
}

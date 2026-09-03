import Foundation

struct ClipboardTextContent: Hashable, Sendable {
    var text: String
    var rtfData: Data?
    var htmlData: Data?
}

struct ClipboardImageContent: Hashable, Sendable {
    var associatedText: String
    var payload: ClipboardImagePayload
}

/// A clip that is a URL rather than loose text: a file copied in Finder, or a
/// link copied from a browser. Both arrive on the pasteboard as URLs and both
/// need to be written back as URLs, so they share one kind and are told apart
/// by `isFileURL` wherever the difference matters.
struct ClipboardLinkContent: Hashable, Sendable {
    var url: URL
    /// A page title for a web link, or the display name for a file.
    var title: String?

    var isFileURL: Bool {
        url.isFileURL
    }

    /// What the clip reads as, and what gets written back as plain text.
    var displayText: String {
        url.isFileURL ? url.path : url.absoluteString
    }

    /// The containing folder for a file URL, or the host for a web link. The file's
    /// own name is already the clip's title, so repeating it here would say nothing.
    var subtitle: String? {
        guard url.isFileURL else { return url.host }
        let folder = url.deletingLastPathComponent().path
        guard !folder.isEmpty, folder != "/" else { return folder.isEmpty ? nil : "/" }
        let home = NSHomeDirectory()
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") {
            return "~" + folder.dropFirst(home.count)
        }
        return folder
    }
}

enum ClipboardContent: Hashable, Sendable {
    case text(ClipboardTextContent)
    case image(ClipboardImageContent)
    case link(ClipboardLinkContent)

    var kind: ClipboardContentKind {
        switch self {
        case .text: .text
        case .image: .image
        case .link: .link
        }
    }

    var text: String {
        switch self {
        case .text(let content): content.text
        case .image(let content): content.associatedText
        case .link(let content): content.displayText
        }
    }
}

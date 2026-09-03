import Foundation

enum ClipboardContentFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case images
    case links
    case pinned

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            "All"
        case .text:
            "Text"
        case .images:
            "Images"
        case .links:
            "Links"
        case .pinned:
            "Pinned"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            true
        case .text:
            item.contentKind == .text
        case .images:
            item.isImage
        case .links:
            item.contentKind == .link
        case .pinned:
            item.isPinned
        }
    }
}

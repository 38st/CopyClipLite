import Foundation

enum ClipboardContentFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case images
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
        case .pinned:
            item.isPinned
        }
    }
}

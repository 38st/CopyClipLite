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

enum ClipboardContent: Hashable, Sendable {
    case text(ClipboardTextContent)
    case image(ClipboardImageContent)

    var kind: ClipboardContentKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }

    var text: String {
        switch self {
        case .text(let content): content.text
        case .image(let content): content.associatedText
        }
    }
}

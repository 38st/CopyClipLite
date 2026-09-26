import AppKit
import Foundation

struct ClipboardPasteboardWriteRequest: Sendable, Equatable {
    let required: [ClipboardPasteboardRepresentation]
    let optional: [ClipboardPasteboardRepresentation]

    static func plainText(_ text: String) -> Self {
        Self(
            required: [ClipboardPasteboardRepresentation(.string, value: .string(text))],
            optional: []
        )
    }

    static func copying(
        _ item: ClipboardItem,
        imageData: Data?,
        includingRichText: Bool = true
    ) -> Self? {
        switch item.contentKind {
        case .text:
            var optional: [ClipboardPasteboardRepresentation] = []
            if includingRichText {
                if let rtfData = item.rtfData {
                    optional.append(ClipboardPasteboardRepresentation(.rtf, value: .data(rtfData)))
                }
                if let htmlData = item.htmlData {
                    optional.append(ClipboardPasteboardRepresentation(.html, value: .data(htmlData)))
                }
            }
            return Self(required: plainText(item.text).required, optional: optional)
        case .image:
            guard let imageData else { return nil }
            return Self(
                required: [ClipboardPasteboardRepresentation(.png, value: .data(imageData))],
                optional: item.text.isEmpty ? [] : plainText(item.text).required
            )
        case .link:
            guard let link = item.link else { return nil }
            // Text is required for any destination; the typed URL is optional so
            // destinations such as Finder can receive the file itself.
            let urlType: NSPasteboard.PasteboardType = link.isFileURL ? .fileURL : .URL
            return Self(
                required: plainText(link.displayText).required,
                optional: [
                    ClipboardPasteboardRepresentation(
                        urlType,
                        value: .string(link.url.absoluteString)
                    )
                ]
            )
        }
    }
}

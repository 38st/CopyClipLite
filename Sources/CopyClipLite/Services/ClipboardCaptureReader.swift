import AppKit
import Foundation

struct CapturedTextSnapshot: Sendable {
    let text: String
    let rtfData: Data?
    let htmlData: Data?
}

struct CapturedTextResult: Sendable {
    let snapshot: CapturedTextSnapshot?
    let warning: String?
}

enum ClipboardCaptureReader {
    static func text(from pasteboard: NSPasteboard) -> CapturedTextResult {
        let rawRTFData = pasteboard.data(forType: .rtf)
        let rawHTMLData = pasteboard.data(forType: .html)
        let rtfData = rawRTFData.flatMap {
            $0.count <= ClipboardStorage.maximumImportedRichTextBytes ? $0 : nil
        }
        let htmlData = rawHTMLData.flatMap {
            $0.count <= ClipboardStorage.maximumImportedRichTextBytes ? $0 : nil
        }
        let droppedFormats = [
            rawRTFData != nil && rtfData == nil ? "RTF" : nil,
            rawHTMLData != nil && htmlData == nil ? "HTML" : nil
        ].compactMap { $0 }
        let warning = droppedFormats.isEmpty
            ? nil
            : "The text was saved without oversized \(droppedFormats.joined(separator: " and ")) formatting."
        let text = pasteboard.string(forType: .string)
            ?? attributedPlainText(data: rtfData, documentType: .rtf)
            ?? attributedPlainText(data: htmlData, documentType: .html)

        guard let text,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
            return CapturedTextResult(snapshot: nil, warning: warning)
        }
        guard text.count <= ClipboardStorage.maximumImportedTextCharacters else {
            return CapturedTextResult(
                snapshot: nil,
                warning: "A text clip was skipped because it exceeds 20,000 characters."
            )
        }

        return CapturedTextResult(
            snapshot: CapturedTextSnapshot(text: text, rtfData: rtfData, htmlData: htmlData),
            warning: warning
        )
    }

    static func image(from pasteboard: NSPasteboard) -> ClipboardImageCandidate? {
        var sources: [ClipboardImageCandidateSource] = []
        if let data = pasteboard.data(forType: .png) {
            sources.append(.data(data, isPNG: true))
        }
        if let data = pasteboard.data(forType: .tiff) {
            sources.append(.data(data, isPNG: false))
        }
        for type in [
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif")
        ] {
            if let data = pasteboard.data(forType: type) {
                sources.append(.data(data, isPNG: false))
            }
        }
        if let fileURLString = pasteboard.string(forType: .fileURL),
           let fileURL = URL(string: fileURLString),
           fileURL.isFileURL {
            sources.append(.fileURL(fileURL))
        }
        return sources.isEmpty ? nil : ClipboardImageCandidate(sources: sources)
    }

    private static func attributedPlainText(
        data: Data?,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        guard let data else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        ).string
    }
}

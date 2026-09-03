import Foundation

struct ClipboardSearchQuery: Equatable, Sendable {
    let applicationName: String?
    let freeText: String

    init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4,
              trimmed.prefix(4).caseInsensitiveCompare("app:") == .orderedSame else {
            applicationName = nil
            freeText = trimmed
            return
        }

        let scopedValue = trimmed.dropFirst(4)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.parseScope(scopedValue)
        guard !parsed.applicationName.isEmpty else {
            applicationName = nil
            freeText = trimmed
            return
        }
        applicationName = parsed.applicationName
        freeText = parsed.freeText
    }

    func matches(_ item: ClipboardItem) -> Bool {
        guard let applicationName else {
            return freeText.isEmpty
                || item.searchableText.localizedCaseInsensitiveContains(freeText)
        }
        guard item.sourceApplication?.name.localizedCaseInsensitiveContains(applicationName)
                == true else {
            return false
        }
        return freeText.isEmpty
            || contentText(for: item).localizedCaseInsensitiveContains(freeText)
    }

    private static func parseScope(
        _ value: String
    ) -> (applicationName: String, freeText: String) {
        if value.first == "\"",
           let closingQuote = value.dropFirst().firstIndex(of: "\"") {
            let applicationName = String(value[value.index(after: value.startIndex)..<closingQuote])
            let freeText = value[value.index(after: closingQuote)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (applicationName, freeText)
        }

        let components = value.split(
            maxSplits: 1,
            whereSeparator: { $0.isWhitespace }
        )
        return (
            components.first.map(String.init) ?? "",
            components.count == 2 ? String(components[1]) : ""
        )
    }

    private func contentText(for item: ClipboardItem) -> String {
        switch item.contentKind {
        case .text:
            return item.text
        case .image:
            return ["image", item.image?.dimensionsText, item.text]
                .compactMap { $0 }
                .joined(separator: " ")
        case .link:
            return [
                item.isFileClip ? "file" : "link",
                item.link?.title,
                item.link?.subtitle,
                item.text,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }
}

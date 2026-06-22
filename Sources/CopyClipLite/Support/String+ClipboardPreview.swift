import Foundation

extension String {
    var copyClipCharacterCountText: String {
        count == 1 ? "1 character" : "\(count) characters"
    }

    func copyClipPreview(limit: Int) -> String {
        let collapsed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > limit else {
            return collapsed
        }

        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

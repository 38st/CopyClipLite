import Foundation

extension String {
    var copyClipCharacterCountText: String {
        count == 1 ? "1 character" : "\(count) characters"
    }

    func copyClipPreview(limit: Int) -> String {
        let collapsed = reducingInternalWhitespace()

        guard collapsed.count > limit else {
            return collapsed
        }

        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func reducingInternalWhitespace() -> String {
        var result = self.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[\\r\\n]+", with: "\n", options: .regularExpression)
        return result
    }
}

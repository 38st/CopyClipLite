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

    private func reducingInternalWhitespace() -> String {
        var result = ""
        result.reserveCapacity(count)
        var previous: Character?

        for character in self {
            switch character {
            case " ", "\t":
                if previous != " " {
                    result.append(" ")
                }
                previous = " "
            case "\n", "\r":
                if previous != "\n" {
                    result.append("\n")
                }
                previous = "\n"
            default:
                result.append(character)
                previous = character
            }
        }

        return result
    }
}

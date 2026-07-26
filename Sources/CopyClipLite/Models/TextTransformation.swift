import Foundation

enum TextTransformation: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case titleCase
    case stripFormatting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .stripFormatting: return "Strip Formatting"
        }
    }

    var iconName: String {
        switch self {
        case .uppercase: return "textformat.size"
        case .lowercase: return "textformat.size"
        case .titleCase: return "textformat.size"
        case .stripFormatting: return "textformat.alt"
        }
    }

    func applied(to text: String) -> String {
        switch self {
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return text.capitalized
        case .stripFormatting:
            return text
        }
    }
}

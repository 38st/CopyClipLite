import Foundation

enum TextTransformation: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case titleCase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        }
    }

    var iconName: String {
        switch self {
        case .uppercase: return "textformat.size"
        case .lowercase: return "textformat.size"
        case .titleCase: return "textformat.size"
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
        }
    }
}

import Foundation

enum ClipboardRetentionPolicy: String, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case thirtyDays
    case never

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .oneDay:
            "After 24 hours"
        case .sevenDays:
            "After 7 days"
        case .thirtyDays:
            "After 30 days"
        case .never:
            "Never"
        }
    }

    var expirationInterval: TimeInterval? {
        switch self {
        case .oneDay:
            24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .thirtyDays:
            30 * 24 * 60 * 60
        case .never:
            nil
        }
    }
}

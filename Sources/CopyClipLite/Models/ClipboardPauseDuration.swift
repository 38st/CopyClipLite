import Foundation

enum ClipboardPauseDuration: String, CaseIterable, Identifiable {
    case fiveMinutes
    case oneHour
    case untilTomorrow

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .fiveMinutes:
            "5 Minutes"
        case .oneHour:
            "1 Hour"
        case .untilTomorrow:
            "Until Tomorrow"
        }
    }

    func resumeDate(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .fiveMinutes:
            return now.addingTimeInterval(5 * 60)
        case .oneHour:
            return now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 60 * 60)
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
                ?? calendar.startOfDay(for: tomorrow)
        }
    }
}

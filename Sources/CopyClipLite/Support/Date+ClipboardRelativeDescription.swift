import Foundation

extension Date {
    var copyClipRelativeDescription: String {
        copyClipRelativeDescription(relativeTo: Date())
    }

    func copyClipRelativeDescription(relativeTo now: Date) -> String {
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(self)))

        if elapsedSeconds < 10 {
            return "just now"
        }

        if elapsedSeconds < 60 {
            return "\(elapsedSeconds)s ago"
        }

        let minutes = elapsedSeconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        let days = hours / 24
        if days < 7 {
            return "\(days)d ago"
        }

        return Self.copyClipAbsoluteFormatter.string(from: self)
    }

    private static let copyClipAbsoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

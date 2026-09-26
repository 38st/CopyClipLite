import Foundation

extension Date {
    // Bound both arithmetic and calendar formatting, including legacy local data.
    var isSupportedClipboardTimestamp: Bool {
        timeIntervalSinceReferenceDate.isFinite && self >= .distantPast && self <= .distantFuture
    }

    var copyClipRelativeDescription: String {
        copyClipRelativeDescription(relativeTo: Date())
    }

    func copyClipRelativeDescription(relativeTo now: Date) -> String {
        guard isSupportedClipboardTimestamp, now.isSupportedClipboardTimestamp else {
            return "Unknown date"
        }
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

        return self.formatted(date: .abbreviated, time: .shortened)
    }
}

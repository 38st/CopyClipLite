import Foundation

struct ClipboardMonitoringPreferenceState: Equatable, Sendable {
    let isEnabled: Bool
    let pausedUntil: Date?
}

enum ClipboardMonitoringPreferences {
    static func initialState(
        defaults: UserDefaults,
        now: Date,
        enabledKey: String = "monitoringEnabled",
        pausedUntilKey: String = "monitoringPausedUntil"
    ) -> ClipboardMonitoringPreferenceState {
        let storedEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let storedPausedUntil = defaults.object(forKey: pausedUntilKey) as? Date
        if let storedPausedUntil, storedPausedUntil > now {
            return ClipboardMonitoringPreferenceState(
                isEnabled: false,
                pausedUntil: storedPausedUntil
            )
        }
        if storedPausedUntil != nil {
            defaults.set(true, forKey: enabledKey)
            defaults.removeObject(forKey: pausedUntilKey)
            return ClipboardMonitoringPreferenceState(isEnabled: true, pausedUntil: nil)
        }
        return ClipboardMonitoringPreferenceState(
            isEnabled: storedEnabled,
            pausedUntil: nil
        )
    }

    static func statusText(
        isEnabled: Bool,
        pausedUntil: Date?,
        now: Date
    ) -> String {
        if isEnabled { return "Monitoring clipboard" }
        if let pausedUntil, pausedUntil > now {
            return "Paused until \(pauseTimeFormatter.string(from: pausedUntil))"
        }
        return "Paused"
    }

    private static let pauseTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

import Foundation

@MainActor
final class ClipboardMonitoringSchedule {
    private static let maximumResumeSleepInterval: TimeInterval = 60
    private let clock: ClipboardStoreClock
    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var pruneTimer: Timer?
    private var resumeTask: Task<Void, Never>?

    init(clock: ClipboardStoreClock) {
        self.clock = clock
    }

    deinit {
        pollTimer?.invalidate()
        pruneTimer?.invalidate()
        resumeTask?.cancel()
    }

    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    func startPolling(
        interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func startPruning(
        interval: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        pruneTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    func scheduleResume(
        at date: Date,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancelResume()
        guard date > clock.now() else {
            action()
            return
        }
        resumeTask = Task { @MainActor [clock] in
            while !Task.isCancelled {
                let remaining = date.timeIntervalSince(clock.now())
                guard remaining > 0 else {
                    action()
                    return
                }
                let boundedDelay = min(remaining, Self.maximumResumeSleepInterval)
                let nanoseconds = Self.nanoseconds(for: boundedDelay)
                do {
                    try await clock.sleep(nanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 0 }
        let nanoseconds = interval * 1_000_000_000
        return UInt64(min(nanoseconds, Double(UInt64.max)).rounded(.down))
    }
}

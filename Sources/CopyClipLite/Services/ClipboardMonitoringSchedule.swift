import Foundation

@MainActor
final class ClipboardMonitoringSchedule {
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
        let delay = date.timeIntervalSince(clock.now())
        guard delay > 0 else {
            action()
            return
        }
        resumeTask = Task { @MainActor [clock] in
            try? await clock.sleep(UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }
}

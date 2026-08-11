import Foundation

enum PasteAttemptOutcome: Equatable {
    case posted
    case failed(message: String)
    case permissionRevoked
    case cancelled
}

@MainActor
struct PasteAttempt {
    let target: any PasteTargetApplication
    let runtime: PasteTargetRuntime
    let activationTimeoutNanoseconds: UInt64
    let activationPollNanoseconds: UInt64
    let stabilizationNanoseconds: UInt64

    func run(
        isCurrent: @escaping @MainActor () -> Bool,
        onPosting: @escaping @MainActor () -> Void
    ) async -> PasteAttemptOutcome {
        let deadline = clampedSum(
            runtime.monotonicNanoseconds(),
            activationTimeoutNanoseconds
        )
        while !target.pasteIsActive {
            let now = runtime.monotonicNanoseconds()
            guard now < deadline else { break }
            do {
                try await runtime.sleepNanoseconds(
                    min(activationPollNanoseconds, deadline - now)
                )
            } catch {
                return .cancelled
            }
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
        }

        guard target.pasteIsActive else {
            return .failed(message: "The destination app did not become active, so nothing was pasted.")
        }

        do {
            try await runtime.sleepNanoseconds(stabilizationNanoseconds)
        } catch {
            return .cancelled
        }
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        guard !target.pasteIsTerminated, target.pasteIsActive else {
            return .failed(message: "The destination app was no longer ready, so nothing was pasted.")
        }
        guard runtime.isAccessibilityGranted() else {
            return .permissionRevoked
        }

        onPosting()
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        guard !target.pasteIsTerminated, target.pasteIsActive else {
            return .failed(message: "The destination app was no longer ready, so nothing was pasted.")
        }
        guard runtime.isAccessibilityGranted() else {
            return .permissionRevoked
        }
        guard runtime.simulatePaste(target.pasteProcessIdentifier) else {
            return .failed(message: "macOS could not create the paste event.")
        }
        return .posted
    }

    private func clampedSum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

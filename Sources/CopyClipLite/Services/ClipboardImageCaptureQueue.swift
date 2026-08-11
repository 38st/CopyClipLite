import Foundation

struct ClipboardImageCaptureRequest: Sendable {
    let candidate: ClipboardImageCandidate
    let associatedText: CapturedTextSnapshot?
    let associatedWarning: String?
    let sourceApplication: ClipboardSourceApplication?
    let capturedAt: Date
}

enum ClipboardImageCaptureOutcome: Sendable {
    case processed(ClipboardImagePayload, ClipboardImageCaptureRequest)
    case failed(String, ClipboardImageCaptureRequest)
}

@MainActor
final class ClipboardImageCaptureQueue {
    private struct PendingRequest {
        let request: ClipboardImageCaptureRequest
        let generation: UInt64
        let completion: @MainActor @Sendable (ClipboardImageCaptureOutcome) -> Void
    }

    private let processor: any ClipboardImageProcessing
    private let maximumPendingCaptures: Int
    private var pending: [PendingRequest] = []
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var generation: UInt64 = 0

    init(
        processor: any ClipboardImageProcessing,
        maximumPendingCaptures: Int = 8
    ) {
        self.processor = processor
        self.maximumPendingCaptures = maximumPendingCaptures
    }

    deinit {
        worker?.cancel()
    }

    func enqueue(
        _ request: ClipboardImageCaptureRequest,
        completion: @escaping @MainActor @Sendable (ClipboardImageCaptureOutcome) -> Void
    ) {
        let queuedCapacity = maximumPendingCaptures - (worker == nil ? 0 : 1)
        while pending.count >= max(queuedCapacity, 0), !pending.isEmpty {
            pending.removeFirst()
        }
        pending.append(
            PendingRequest(
                request: request,
                generation: generation,
                completion: completion
            )
        )
        startWorkerIfNeeded()
    }

    func invalidate() {
        generation &+= 1
        pending.removeAll()
        worker?.cancel()
        worker = nil
        workerID = nil
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        let id = UUID()
        workerID = id
        worker = Task { @MainActor [weak self] in
            await self?.drain(workerID: id)
        }
    }

    private func drain(workerID: UUID) async {
        defer {
            if self.workerID == workerID {
                worker = nil
                self.workerID = nil
                startWorkerIfNeeded()
            }
        }
        while !Task.isCancelled, !pending.isEmpty {
            let pendingRequest = pending.removeFirst()
            do {
                let image = try await processor.process(pendingRequest.request.candidate)
                guard !Task.isCancelled,
                      generation == pendingRequest.generation else { continue }
                pendingRequest.completion(.processed(image, pendingRequest.request))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      generation == pendingRequest.generation else { continue }
                pendingRequest.completion(
                    .failed(error.localizedDescription, pendingRequest.request)
                )
            }
        }
    }
}

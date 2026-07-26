import Darwin
import Foundation

enum ProcessMemoryMetrics {
    static func residentSizeBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(result))
        }
        return info.resident_size
    }

    static func relieveAllocatorPressure() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    static func positiveGrowth(from baseline: UInt64, to measured: UInt64) -> UInt64 {
        measured >= baseline ? measured - baseline : 0
    }
}

final class ProcessResidentPeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private var isRunning = true
    private var peakResidentBytes: UInt64

    init(baselineResidentBytes: UInt64) {
        peakResidentBytes = baselineResidentBytes
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            started.signal()
            while shouldContinue {
                if let residentBytes = try? ProcessMemoryMetrics.residentSizeBytes() {
                    record(residentBytes)
                }
                usleep(500)
            }
            stopped.signal()
        }
        started.wait()
    }

    func stop() -> UInt64 {
        lock.lock()
        isRunning = false
        lock.unlock()
        stopped.wait()

        lock.lock()
        defer { lock.unlock() }
        return peakResidentBytes
    }

    private var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private func record(_ residentBytes: UInt64) {
        lock.lock()
        peakResidentBytes = max(peakResidentBytes, residentBytes)
        lock.unlock()
    }
}

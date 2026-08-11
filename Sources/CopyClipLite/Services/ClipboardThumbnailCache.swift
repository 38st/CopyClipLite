import Foundation

enum ClipboardThumbnailLookup {
    case data(Data)
    case load
    case unavailable
}

@MainActor
final class ClipboardThumbnailCache {
    private struct Entry {
        let fingerprint: String
        let data: Data
    }

    private let capacity: Int
    private let retryDelay: TimeInterval
    private var entriesByID: [ClipboardItem.ID: Entry] = [:]
    private var order: [ClipboardItem.ID] = []
    private var loadingIDs: Set<ClipboardItem.ID> = []
    private var retryAfter: [ClipboardItem.ID: Date] = [:]

    init(capacity: Int = 100, retryDelay: TimeInterval = 5) {
        self.capacity = capacity
        self.retryDelay = retryDelay
    }

    func lookup(for item: ClipboardItem, now: Date) -> ClipboardThumbnailLookup {
        if let inlineData = item.image?.displayData {
            return .data(inlineData)
        }
        let fingerprint = fingerprint(for: item)
        if let entry = entriesByID[item.id] {
            if entry.fingerprint == fingerprint {
                return .data(entry.data)
            }
            entriesByID.removeValue(forKey: item.id)
            order.removeAll { $0 == item.id }
        }
        guard !loadingIDs.contains(item.id),
              retryAfter[item.id, default: .distantPast] <= now else {
            return .unavailable
        }
        loadingIDs.insert(item.id)
        loadingFingerprints[item.id] = fingerprint
        return .load
    }

    func finishLoading(id: ClipboardItem.ID, data: Data?, now: Date) {
        loadingIDs.remove(id)
        guard let data else {
            loadingFingerprints.removeValue(forKey: id)
            retryAfter[id] = now.addingTimeInterval(retryDelay)
            return
        }
        retryAfter.removeValue(forKey: id)
        // The fingerprint is captured when lookup starts. If the item changes
        // before completion, the next lookup rejects this stale entry.
        let fingerprint = loadingFingerprints.removeValue(forKey: id) ?? ""
        entriesByID[id] = Entry(fingerprint: fingerprint, data: data)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            entriesByID.removeValue(forKey: order.removeFirst())
        }
    }

    private var loadingFingerprints: [ClipboardItem.ID: String] = [:]

    private func fingerprint(for item: ClipboardItem) -> String {
        guard let image = item.image else { return "not-an-image" }
        return [
            image.contentHash ?? "",
            image.fileName ?? "",
            String(image.width),
            String(image.height),
            String(image.byteCount),
        ].joined(separator: "|")
    }
}

import Foundation

struct ClipboardThumbnailLoad: Equatable, Sendable {
    let id: UUID
    let fingerprint: String
}

enum ClipboardThumbnailLookup {
    case data(Data)
    case load(ClipboardThumbnailLoad)
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
    private var loadingByID: [ClipboardItem.ID: ClipboardThumbnailLoad] = [:]
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
        guard loadingByID[item.id] == nil,
              retryAfter[item.id, default: .distantPast] <= now else {
            return .unavailable
        }
        let load = ClipboardThumbnailLoad(id: UUID(), fingerprint: fingerprint)
        loadingByID[item.id] = load
        return .load(load)
    }

    func finishLoading(
        id: ClipboardItem.ID,
        load: ClipboardThumbnailLoad,
        data: Data?,
        now: Date
    ) {
        guard loadingByID[id] == load else { return }
        loadingByID.removeValue(forKey: id)
        guard let data else {
            retryAfter[id] = now.addingTimeInterval(retryDelay)
            return
        }
        retryAfter.removeValue(forKey: id)
        // The fingerprint is captured when lookup starts. If the item changes
        // before completion, the next lookup rejects this stale entry.
        entriesByID[id] = Entry(fingerprint: load.fingerprint, data: data)
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > capacity {
            entriesByID.removeValue(forKey: order.removeFirst())
        }
    }

    func invalidate(ids: Set<ClipboardItem.ID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            entriesByID.removeValue(forKey: id)
            loadingByID.removeValue(forKey: id)
            retryAfter.removeValue(forKey: id)
        }
        order.removeAll { ids.contains($0) }
    }

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

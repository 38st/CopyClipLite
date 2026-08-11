import Foundation

struct ClipboardHistoryPolicy: Equatable, Sendable {
    let unpinnedLimit: Int
    let retentionPolicy: ClipboardRetentionPolicy
}

struct ClipboardHistoryPolicyResult: Equatable, Sendable {
    let items: [ClipboardItem]
    let expiredCount: Int
    let overLimitCount: Int
}

enum ClipboardHistoryRules {
    static func applyingPolicy(
        to candidateItems: [ClipboardItem],
        policy: ClipboardHistoryPolicy,
        now: Date
    ) -> ClipboardHistoryPolicyResult {
        var retained = candidateItems.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let countBeforeExpiration = retained.count
        if let expirationInterval = policy.retentionPolicy.expirationInterval {
            let cutoffDate = now.addingTimeInterval(-expirationInterval)
            retained.removeAll { !$0.isPinned && $0.lastCopiedAt < cutoffDate }
        }
        let expiredCount = countBeforeExpiration - retained.count

        let countBeforeLimit = retained.count
        var unpinnedCount = 0
        retained.removeAll { item in
            guard !item.isPinned else { return false }
            unpinnedCount += 1
            return unpinnedCount > policy.unpinnedLimit
        }
        return ClipboardHistoryPolicyResult(
            items: retained,
            expiredCount: expiredCount,
            overLimitCount: countBeforeLimit - retained.count
        )
    }

    static func merging(
        existing: [ClipboardItem],
        imported: [ClipboardItem]
    ) -> [ClipboardItem] {
        var result = existing

        for importedItem in imported {
            let matchingIndex = result.firstIndex {
                matchesForImport($0, importedItem)
            }
            guard let matchingIndex else {
                result.append(importedItem)
                continue
            }

            let existingItem = result[matchingIndex]
            var preferred = existingItem.lastCopiedAt >= importedItem.lastCopiedAt
                ? existingItem
                : importedItem
            preferred.isPinned = existingItem.isPinned || importedItem.isPinned
            preferred.copyCount = max(existingItem.copyCount, importedItem.copyCount)
            result[matchingIndex] = preferred
        }

        return result.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    static func recordingText(
        _ text: String,
        rtfData: Data?,
        htmlData: Data?,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        var items = currentItems
        if let existingIndex = items.firstIndex(where: {
            $0.contentKind == .text && $0.text == text
        }) {
            var existing = items.remove(at: existingIndex)
            let isNewestRepresentation = capturedAt >= existing.lastCopiedAt
            existing.lastCopiedAt = max(existing.lastCopiedAt, capturedAt)
            existing.copyCount = incrementedCopyCount(existing.copyCount)
            if isNewestRepresentation {
                existing.sourceApplication = sourceApplication ?? existing.sourceApplication
                existing.rtfData = rtfData
                existing.htmlData = htmlData
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(
                ClipboardItem(
                    text: text,
                    rtfData: rtfData,
                    htmlData: htmlData,
                    createdAt: capturedAt,
                    lastCopiedAt: capturedAt,
                    sourceApplication: sourceApplication
                ),
                at: 0
            )
        }
        return items
    }

    static func recordingImage(
        _ image: ClipboardImagePayload,
        associatedText: String?,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        var items = currentItems
        if let existingIndex = items.firstIndex(where: {
            guard let existingHash = $0.image?.contentHash,
                  let newHash = image.contentHash else {
                return false
            }
            return existingHash == newHash
        }) {
            var existing = items.remove(at: existingIndex)
            let isNewestRepresentation = capturedAt >= existing.lastCopiedAt
            existing.lastCopiedAt = max(existing.lastCopiedAt, capturedAt)
            existing.copyCount = incrementedCopyCount(existing.copyCount)
            if isNewestRepresentation {
                existing.sourceApplication = sourceApplication ?? existing.sourceApplication
                existing.text = associatedText ?? ""
                existing.image = image
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(
                ClipboardItem(
                    text: associatedText ?? "",
                    image: image,
                    createdAt: capturedAt,
                    lastCopiedAt: capturedAt,
                    sourceApplication: sourceApplication
                ),
                at: 0
            )
        }
        return items.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    private static func matchesForImport(
        _ existingItem: ClipboardItem,
        _ importedItem: ClipboardItem
    ) -> Bool {
        if existingItem.id == importedItem.id { return true }
        guard existingItem.contentKind == importedItem.contentKind else { return false }
        switch importedItem.contentKind {
        case .text:
            return existingItem.text == importedItem.text
        case .image:
            guard let importedHash = importedItem.image?.contentHash else { return false }
            return existingItem.image?.contentHash == importedHash
        }
    }

    private static func incrementedCopyCount(_ copyCount: Int) -> Int {
        guard copyCount < ClipboardItem.maximumCopyCount else {
            return ClipboardItem.maximumCopyCount
        }
        return max(copyCount + 1, 1)
    }
}

import Foundation

enum ClipboardImportPlanner {
    static func plan(
        artifact: ClipboardImportArtifact,
        currentItems: [ClipboardItem],
        policy: ClipboardHistoryPolicy,
        retentionPolicy: ClipboardRetentionPolicy,
        now: Date
    ) -> ClipboardImportPlan {
        let mergeBeforePruning = ClipboardHistoryRules.merging(
            existing: currentItems,
            imported: artifact.items
        )
        let replaceBeforePruning = artifact.items.sorted {
            $0.lastCopiedAt > $1.lastCopiedAt
        }
        let merge = candidate(
            beforePruning: mergeBeforePruning,
            sourceItemCount: artifact.items.count,
            addedCount: max(mergeBeforePruning.count - currentItems.count, 0),
            strategy: .merge,
            policy: policy,
            now: now
        )
        let replace = candidate(
            beforePruning: replaceBeforePruning,
            sourceItemCount: artifact.items.count,
            addedCount: artifact.items.count,
            strategy: .replace,
            policy: policy,
            now: now
        )
        return ClipboardImportPlan(
            artifact: artifact,
            currentItems: currentItems,
            historyLimit: policy.unpinnedLimit,
            retentionPolicy: retentionPolicy,
            mergeItems: merge.items,
            mergeProjection: merge.projection,
            replaceItems: replace.items,
            replaceProjection: replace.projection
        )
    }

    private static func candidate(
        beforePruning: [ClipboardItem],
        sourceItemCount: Int,
        addedCount: Int,
        strategy: ClipboardImportStrategy,
        policy: ClipboardHistoryPolicy,
        now: Date
    ) -> (items: [ClipboardItem], projection: ClipboardImportProjection) {
        let policyResult = ClipboardHistoryRules.applyingPolicy(
            to: beforePruning,
            policy: policy,
            now: now
        )
        let finalItems = policyResult.items
        return (
            finalItems,
            ClipboardImportProjection(
                strategy: strategy,
                sourceItemCount: sourceItemCount,
                addedCount: addedCount,
                deduplicatedCount: strategy == .merge
                    ? max(sourceItemCount - addedCount, 0)
                    : 0,
                expiredCount: policyResult.expiredCount,
                overLimitCount: policyResult.overLimitCount,
                retainedPinnedCount: finalItems.filter(\.isPinned).count,
                finalCount: finalItems.count
            )
        )
    }
}

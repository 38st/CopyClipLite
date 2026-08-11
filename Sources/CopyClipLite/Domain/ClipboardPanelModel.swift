import Foundation

enum ClipboardPanelModel {
    static func displayedItems(_ visibleItems: [ClipboardItem]) -> [ClipboardItem] {
        visibleItems.filter(\.isPinned) + visibleItems.filter { !$0.isPinned }
    }

    static func reconciledSelection(
        selectedID: ClipboardItem.ID?,
        displayedItems: [ClipboardItem]
    ) -> ClipboardItem.ID? {
        if let selectedID,
           displayedItems.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return displayedItems.first?.id
    }

    static func movedSelection(
        selectedID: ClipboardItem.ID?,
        by offset: Int,
        displayedItems: [ClipboardItem]
    ) -> ClipboardItem.ID? {
        guard !displayedItems.isEmpty else { return nil }
        guard let selectedID,
              let selectedIndex = displayedItems.firstIndex(where: { $0.id == selectedID }) else {
            return displayedItems.first?.id
        }
        let nextIndex = min(max(selectedIndex + offset, 0), displayedItems.count - 1)
        return displayedItems[nextIndex].id
    }

    static func selectionAfterDeleting(
        deletedID: ClipboardItem.ID,
        selectedID: ClipboardItem.ID?,
        before: [ClipboardItem],
        after: [ClipboardItem]
    ) -> ClipboardItem.ID? {
        guard selectedID == deletedID,
              let deletedIndex = before.firstIndex(where: { $0.id == deletedID }) else {
            return selectedID.flatMap { selected in
                after.contains(where: { $0.id == selected }) ? selected : after.first?.id
            }
        }
        guard !after.isEmpty else { return nil }
        return after[min(deletedIndex, after.count - 1)].id
    }

    static func selectedPositionChanged(
        selectedID: ClipboardItem.ID?,
        beforeIDs: [ClipboardItem.ID],
        afterIDs: [ClipboardItem.ID]
    ) -> Bool {
        guard let selectedID,
              let oldIndex = beforeIDs.firstIndex(of: selectedID),
              let newIndex = afterIDs.firstIndex(of: selectedID) else {
            return false
        }
        return oldIndex != newIndex
    }
}

// Retain the existing internal name while callers migrate to the model boundary.
typealias ClipboardPanelOrdering = ClipboardPanelModel

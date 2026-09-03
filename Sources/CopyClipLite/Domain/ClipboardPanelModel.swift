import Foundation

enum ClipboardPanelSelectionModifier: Equatable {
    case single
    case toggle
    case range
}

struct ClipboardPanelSelection: Equatable {
    var selectedIDs: Set<ClipboardItem.ID> = []
    var primaryID: ClipboardItem.ID?
    var anchorID: ClipboardItem.ID?

    static func single(_ id: ClipboardItem.ID?) -> ClipboardPanelSelection {
        ClipboardPanelSelection(
            selectedIDs: id.map { [$0] } ?? [],
            primaryID: id,
            anchorID: id
        )
    }
}

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

    static func selection(
        afterSelecting id: ClipboardItem.ID,
        modifier: ClipboardPanelSelectionModifier,
        current: ClipboardPanelSelection,
        displayedItems: [ClipboardItem]
    ) -> ClipboardPanelSelection {
        guard displayedItems.contains(where: { $0.id == id }) else {
            return current
        }

        switch modifier {
        case .single:
            return .single(id)
        case .toggle:
            var selectedIDs = current.selectedIDs
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
            let primaryID = selectedIDs.contains(id)
                ? id
                : displayedItems.first(where: { selectedIDs.contains($0.id) })?.id
            return ClipboardPanelSelection(
                selectedIDs: selectedIDs,
                primaryID: primaryID,
                anchorID: id
            )
        case .range:
            let anchorID = current.anchorID ?? current.primaryID ?? id
            guard let anchorIndex = displayedItems.firstIndex(where: { $0.id == anchorID }),
                  let selectedIndex = displayedItems.firstIndex(where: { $0.id == id }) else {
                return .single(id)
            }
            let bounds = min(anchorIndex, selectedIndex)...max(anchorIndex, selectedIndex)
            return ClipboardPanelSelection(
                selectedIDs: Set(bounds.map { displayedItems[$0].id }),
                primaryID: id,
                anchorID: anchorID
            )
        }
    }

    static func reconciledSelection(
        _ selection: ClipboardPanelSelection,
        displayedItems: [ClipboardItem]
    ) -> ClipboardPanelSelection {
        let displayedIDs = Set(displayedItems.map(\.id))
        let selectedIDs = selection.selectedIDs.intersection(displayedIDs)
        if selectedIDs.isEmpty {
            return .single(displayedItems.first?.id)
        }
        let primaryID = selection.primaryID.flatMap { selectedIDs.contains($0) ? $0 : nil }
            ?? displayedItems.first(where: { selectedIDs.contains($0.id) })?.id
        let anchorID = selection.anchorID.flatMap { displayedIDs.contains($0) ? $0 : nil }
            ?? primaryID
        return ClipboardPanelSelection(
            selectedIDs: selectedIDs,
            primaryID: primaryID,
            anchorID: anchorID
        )
    }

    static func item(
        forQuickSelectionNumber number: Int,
        displayedItems: [ClipboardItem]
    ) -> ClipboardItem? {
        guard (1...9).contains(number), displayedItems.indices.contains(number - 1) else {
            return nil
        }
        return displayedItems[number - 1]
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

import AppKit
import SwiftUI

enum ClipboardPanelPresentationContext: Equatable {
    case menuBar
    case mainWindow

    var showsOpenMainWindowButton: Bool {
        self == .menuBar
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteTargetController: PasteTargetController
    let presentationContext: ClipboardPanelPresentationContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var contentFilter: ClipboardContentFilter = .all
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var isConfirmingClear = false
    @FocusState private var isSearchFocused: Bool
    @AccessibilityFocusState private var accessibilityFocusedItemID: ClipboardItem.ID?

    var body: some View {
        let visible = store.visibleItems(matching: searchText, filter: contentFilter)
        let pinned = visible.filter(\.isPinned)
        let recent = visible.filter { !$0.isPinned }

        return VStack(spacing: 0) {
            ClipboardPanelHeader(
                store: store,
                showsOpenMainWindowButton: presentationContext.showsOpenMainWindowButton,
                openMainWindow: openMainWindow
            )

            Divider()

            ClipboardPanelSearchControls(
                searchText: $searchText,
                contentFilter: $contentFilter,
                issueMessage: displayedIssue?.message,
                submit: { _ = copySelectedItem() },
                dismissIssue: dismissIssue,
                searchFocus: $isSearchFocused
            )

            ClipboardPanelHistoryList(
                visible: visible,
                pinned: pinned,
                recent: recent,
                emptyReason: emptyHistoryReason,
                selectedItemID: $selectedItemID,
                reduceMotion: reduceMotion,
                row: row
            )

            Divider()

            ClipboardPanelFooter(
                historySummary: store.historySummaryText,
                clearableItemCount: clearableItemCount,
                keepPinnedOnClear: store.keepPinnedOnClear,
                requestClear: { isConfirmingClear = true }
            )
        }
        .background(.regularMaterial)
        .confirmationDialog(
            clearConfirmationTitle,
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(clearConfirmationActionTitle, role: .destructive) {
                clearHistory()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearConfirmationMessage)
        }
        .background(
            ClipboardPanelKeyboardBridge { action in
                handleKeyAction(action)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            focusSearch()
            reconcileSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyClipFocusSearch)) { _ in
            focusSearch()
            reconcileSelection()
        }
        .onChange(of: visible.map(\.id)) { _, _ in
            reconcileSelection()
        }
        .onChange(of: selectedItemID) { _, newID in
            accessibilityFocusedItemID = newID
        }
    }

    private func row(for item: ClipboardItem) -> some View {
        ClipboardItemRow(
            item: item,
            rowID: item.id,
            isCopied: store.lastCopiedID == item.id,
            isSelected: selectedItemID == item.id,
            thumbnailData: store.cachedThumbnailData(for: item),
            activate: {
                selectedItemID = item.id
                if store.directPasteEnabled {
                    pasteTargetController.paste(item, using: store)
                } else {
                    store.copy(item)
                }
            },
            copy: {
                selectedItemID = item.id
                store.copy(item)
            },
            togglePin: {
                selectedItemID = item.id
                store.togglePin(item)
            },
            delete: {
                deleteItem(item)
            },
            ignoreApplication: ignoreApplicationAction(for: item),
            transform: item.contentKind == .text ? { transformation in
                selectedItemID = item.id
                store.copyWithTransformation(item, transformation: transformation)
            } : nil,
            dragProvider: {
                store.dragItemProvider(for: item)
            }
        )
        .accessibilityFocused($accessibilityFocusedItemID, equals: item.id)
    }

    private func ignoreApplicationAction(for item: ClipboardItem) -> (() -> Void)? {
        guard let application = item.sourceApplication,
              !store.isApplicationIgnored(application) else {
            return nil
        }

        return {
            store.addIgnoredApplication(application)
        }
    }

    private func handleKeyAction(_ action: ClipboardPanelKeyAction) -> Bool {
        switch action {
        case .moveUp:
            return moveSelection(by: -1)
        case .moveDown:
            return moveSelection(by: 1)
        case .copySelected:
            return copySelectedItem()
        case .deleteSelected:
            return deleteSelectedItem()
        case .togglePinSelected:
            return togglePinSelectedItem()
        case .focusSearch:
            focusSearch()
            return true
        }
    }

    private var emptyHistoryReason: EmptyHistoryReason {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if store.items.isEmpty {
            return isSearching ? .noMatches : .noHistory
        }

        if isSearching {
            return .noMatches
        }

        switch contentFilter {
        case .all:
            return .noHistory
        case .text:
            return .noTextClips
        case .images:
            return .noImageClips
        case .pinned:
            return .noPinnedClips
        }
    }

    private var clearableItemCount: Int {
        if store.keepPinnedOnClear {
            return store.items.filter { !$0.isPinned }.count
        }

        return store.items.count
    }

    private var clearConfirmationTitle: String {
        store.keepPinnedOnClear ? "Clear Unpinned Clips?" : "Clear All Clips?"
    }

    private var clearConfirmationActionTitle: String {
        store.keepPinnedOnClear ? "Clear Unpinned" : "Clear All"
    }

    private var clearConfirmationMessage: String {
        let itemText = clearableItemCount == 1 ? "1 clip" : "\(clearableItemCount) clips"

        if store.keepPinnedOnClear {
            return "This will delete \(itemText). Pinned clips will stay in your history."
        }

        return "This will permanently delete \(itemText) from your history."
    }

    private func clearHistory() {
        store.clearHistory()
        selectedItemID = nil
        reconcileSelection()
    }

    private func moveSelection(by offset: Int) -> Bool {
        let visibleItems = displayedItems()
        let nextSelection = ClipboardPanelModel.movedSelection(
            selectedID: selectedItemID,
            by: offset,
            displayedItems: visibleItems
        )
        selectedItemID = nextSelection
        return nextSelection != nil
    }

    private func copySelectedItem() -> Bool {
        let visibleItems = displayedItems()
        guard let item = selectedItem() ?? visibleItems.first else {
            return false
        }

        selectedItemID = item.id
        if store.directPasteEnabled {
            pasteTargetController.paste(item, using: store)
        } else {
            store.copy(item)
        }
        return true
    }

    private func deleteSelectedItem() -> Bool {
        guard let item = selectedItem() else {
            return false
        }

        deleteItem(item)
        return true
    }

    private func deleteItem(_ item: ClipboardItem) {
        let before = displayedItems()
        store.delete(item)
        let after = displayedItems()
        selectedItemID = ClipboardPanelOrdering.selectionAfterDeleting(
            deletedID: item.id,
            selectedID: selectedItemID,
            before: before,
            after: after
        )
    }

    private func togglePinSelectedItem() -> Bool {
        guard let item = selectedItem() else {
            return false
        }

        store.togglePin(item)
        return true
    }

    private func selectedItem() -> ClipboardItem? {
        guard let selectedItemID else {
            return nil
        }

        return displayedItems().first { $0.id == selectedItemID }
    }

    private func reconcileSelection() {
        selectedItemID = ClipboardPanelModel.reconciledSelection(
            selectedID: selectedItemID,
            displayedItems: displayedItems()
        )
    }

    private func displayedItems() -> [ClipboardItem] {
        ClipboardPanelOrdering.displayedItems(
            store.visibleItems(matching: searchText, filter: contentFilter)
        )
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .copyClipFocusSearch, object: nil)
    }

    private enum DisplayedIssue {
        case paste(String)
        case storage(String)
        case pasteboardWrite(String)
        case capture(String)

        var message: String {
            switch self {
            case let .paste(message),
                 let .storage(message),
                 let .pasteboardWrite(message),
                 let .capture(message):
                message
            }
        }
    }

    private var displayedIssue: DisplayedIssue? {
        if let message = pasteTargetController.lastError {
            return .paste(message)
        }
        if let message = store.storageErrorMessage {
            return .storage(message)
        }
        if let message = store.pasteboardWriteWarning {
            return .pasteboardWrite(message)
        }
        if let message = store.captureWarning {
            return .capture(message)
        }
        return nil
    }

    private func dismissIssue() {
        switch displayedIssue {
        case .paste:
            pasteTargetController.dismissError()
        case .storage:
            store.dismissStorageError()
        case .pasteboardWrite:
            store.dismissPasteboardWriteWarning()
        case .capture:
            store.dismissCaptureWarning()
        case nil:
            break
        }
    }
}

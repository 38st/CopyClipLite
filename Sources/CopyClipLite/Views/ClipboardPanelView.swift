import AppKit
import SwiftUI

enum ClipboardPanelOrdering {
    static func displayedItems(_ visibleItems: [ClipboardItem]) -> [ClipboardItem] {
        visibleItems.filter(\.isPinned) + visibleItems.filter { !$0.isPinned }
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
        guard !after.isEmpty else {
            return nil
        }
        return after[min(deletedIndex, after.count - 1)].id
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteTargetController: PasteTargetController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var contentFilter: ClipboardContentFilter = .all
    @State private var selectedItemID: ClipboardItem.ID?
    @State private var isConfirmingClear = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let visible = store.visibleItems(matching: searchText, filter: contentFilter)
        let pinned = visible.filter(\.isPinned)
        let recent = visible.filter { !$0.isPinned }

        return VStack(spacing: 0) {
            header

            Divider()

            VStack(spacing: 8) {
                searchField
                filterPicker
                if let displayedIssue {
                    IssueBanner(message: displayedIssue.message, dismiss: dismissIssue)
                }
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            content(visible: visible, pinned: pinned, recent: recent)

            Divider()

            footer
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 1) {
                Text("CopyClip Lite")
                    .font(.headline)

                Text(store.monitoringStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .copyClipFocusSearch, object: nil)
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Open window")
            .accessibilityLabel("Open main window")

            Menu {
                if store.isMonitoringEnabled {
                    Button("Pause") {
                        store.setMonitoringEnabled(false)
                    }
                } else {
                    Button("Resume") {
                        store.setMonitoringEnabled(true)
                    }
                }

                Divider()

                ForEach(ClipboardPauseDuration.allCases) { duration in
                    Button("Pause \(duration.title)") {
                        store.pauseMonitoring(for: duration)
                    }
                }
            } label: {
                Image(systemName: store.isMonitoringEnabled ? "pause.circle" : "play.circle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Monitoring")
            .accessibilityLabel("Monitoring")

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search history", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    _ = copySelectedItem()
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
        )
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $contentFilter) {
            ForEach(ClipboardContentFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private func content(visible: [ClipboardItem], pinned: [ClipboardItem], recent: [ClipboardItem]) -> some View {
        if visible.isEmpty {
            EmptyHistoryView(reason: emptyHistoryReason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !pinned.isEmpty {
                            SectionHeader(title: "Pinned")

                            ForEach(pinned) { item in
                                row(for: item)
                            }
                        }

                        if !recent.isEmpty {
                            SectionHeader(title: pinned.isEmpty ? "Recent" : "History")

                            ForEach(recent) { item in
                                row(for: item)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .onChange(of: selectedItemID) { _, newID in
                    if let newID {
                        scroll(to: newID, using: proxy)
                    }
                }
                .onChange(of: ClipboardPanelOrdering.displayedItems(visible).map(\.id)) { _, _ in
                    if let selectedItemID {
                        scroll(to: selectedItemID, using: proxy)
                    }
                }
            }
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
            } : nil
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(store.historySummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Text("↑↓ · ↩ · ⌘P")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Arrow keys select, Return uses a clip, Command-P pins")

            Spacer()

            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(clearableItemCount == 0)
            .help(clearButtonHelp)
            .accessibilityLabel(clearButtonAccessibilityLabel)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .help("Quit CopyClip Lite")
            .accessibilityLabel("Quit CopyClip Lite")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    private var clearButtonHelp: String {
        store.keepPinnedOnClear ? "Clear unpinned clips" : "Clear all clips"
    }

    private var clearButtonAccessibilityLabel: String {
        store.keepPinnedOnClear ? "Clear unpinned clips" : "Clear all clips"
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
        guard !visibleItems.isEmpty else {
            selectedItemID = nil
            return false
        }

        guard let currentSelectionID = selectedItemID,
              let selectedIndex = visibleItems.firstIndex(where: { $0.id == currentSelectionID }) else {
            selectedItemID = visibleItems.first?.id
            return true
        }

        let nextIndex = min(max(selectedIndex + offset, 0), visibleItems.count - 1)
        selectedItemID = visibleItems[nextIndex].id
        return true
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
        let visibleItems = displayedItems()

        if let selectedItemID,
           visibleItems.contains(where: { $0.id == selectedItemID }) {
            return
        }

        selectedItemID = visibleItems.first?.id
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

    private func scroll(
        to id: ClipboardItem.ID,
        using proxy: ScrollViewProxy
    ) {
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private enum DisplayedIssue {
        case paste(String)
        case storage(String)
        case capture(String)

        var message: String {
            switch self {
            case let .paste(message), let .storage(message), let .capture(message):
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
        case .capture:
            store.dismissCaptureWarning()
        case nil:
            break
        }
    }
}

private struct IssueBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss warning")
        }
        .padding(8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }
}

private enum EmptyHistoryReason {
    case noHistory
    case noMatches
    case noTextClips
    case noImageClips
    case noPinnedClips

    var systemImage: String {
        switch self {
        case .noHistory:
            "clipboard"
        case .noMatches:
            "magnifyingglass"
        case .noTextClips:
            "text.alignleft"
        case .noImageClips:
            "photo"
        case .noPinnedClips:
            "pin"
        }
    }

    var title: String {
        switch self {
        case .noHistory:
            "Copy something to start"
        case .noMatches:
            "No matches"
        case .noTextClips:
            "No text clips"
        case .noImageClips:
            "No image clips"
        case .noPinnedClips:
            "No pinned clips"
        }
    }

    var message: String {
        switch self {
        case .noHistory:
            "Recent clips will appear here."
        case .noMatches:
            "Try a different search or filter."
        case .noTextClips:
            "Text clips will appear here."
        case .noImageClips:
            "Image clips will appear here."
        case .noPinnedClips:
            "Pinned clips will stay at the top."
        }
    }
}

private struct EmptyHistoryView: View {
    let reason: EmptyHistoryReason

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: reason.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text(reason.title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Text(reason.message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

import AppKit
import SwiftUI

struct ClipboardPanelHeader: View {
    @ObservedObject var store: ClipboardStore
    let showsOpenMainWindowButton: Bool
    let openMainWindow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("CopyClip Lite").font(.headline)
                Text(store.monitoringStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsOpenMainWindowButton {
                Button(action: openMainWindow) {
                    Image(systemName: "macwindow").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Open window")
                .accessibilityLabel("Open main window")
            }
            Menu {
                Button(store.isMonitoringEnabled ? "Pause" : "Resume") {
                    store.setMonitoringEnabled(!store.isMonitoringEnabled)
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
                Image(systemName: "gearshape").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct ClipboardPanelSearchControls: View {
    @Binding var searchText: String
    @Binding var contentFilter: ClipboardContentFilter
    let issueMessage: String?
    let submit: () -> Void
    let dismissIssue: () -> Void
    let searchFocus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history or app:Safari", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused(searchFocus)
                    .onSubmit(submit)
                    .help("Use app:name to search clips from one app. Put names with spaces in quotes.")
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
            Picker("Filter", selection: $contentFilter) {
                ForEach(ClipboardContentFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let issueMessage {
                IssueBanner(message: issueMessage, dismiss: dismissIssue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct ClipboardPanelHistoryList<Row: View>: View {
    let visible: [ClipboardItem]
    let pinned: [ClipboardItem]
    let recent: [ClipboardItem]
    let emptyReason: EmptyHistoryReason
    @Binding var selectedItemID: ClipboardItem.ID?
    let reduceMotion: Bool
    @ViewBuilder let row: (ClipboardItem) -> Row

    var body: some View {
        if visible.isEmpty {
            EmptyHistoryView(reason: emptyReason)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if !pinned.isEmpty {
                            SectionHeader(title: "Pinned")
                            ForEach(pinned, content: row)
                        }
                        if !recent.isEmpty {
                            SectionHeader(title: pinned.isEmpty ? "Recent" : "History")
                            ForEach(recent, content: row)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Clipboard history")
                }
                .onChange(of: selectedItemID) { _, newID in
                    if let newID { scroll(to: newID, using: proxy, animated: false) }
                }
                .onChange(of: ClipboardPanelModel.displayedItems(visible).map(\.id)) {
                    oldIDs, newIDs in
                    if let selectedItemID,
                        ClipboardPanelModel.selectedPositionChanged(
                            selectedID: selectedItemID,
                            beforeIDs: oldIDs,
                            afterIDs: newIDs
                        )
                    {
                        scroll(to: selectedItemID, using: proxy, animated: true)
                    }
                }
            }
        }
    }

    private func scroll(to id: ClipboardItem.ID, using proxy: ScrollViewProxy, animated: Bool) {
        if reduceMotion || !animated {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

struct ClipboardPanelFooter: View {
    let historySummary: String
    let clearableItemCount: Int
    let keepPinnedOnClear: Bool
    let selectedItemCount: Int
    let selectedPinnedCount: Int
    let pinSelection: () -> Void
    let unpinSelection: () -> Void
    let requestDeleteSelection: () -> Void
    let requestClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(historySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)
            Text("↑↓ · ↩ · ⌘1–9")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Arrow keys select, Return uses a clip, and Command-1 through Command-9 quickly use a clip")
            Spacer()
            if selectedItemCount > 1 {
                Menu {
                    Button("Pin Selection", action: pinSelection)
                        .disabled(selectedPinnedCount == selectedItemCount)
                    Button("Unpin Selection", action: unpinSelection)
                        .disabled(selectedPinnedCount == 0)
                    Divider()
                    Button(
                        "Delete Selection",
                        role: .destructive,
                        action: requestDeleteSelection
                    )
                } label: {
                    Text("\(selectedItemCount) Selected")
                }
                .help("Actions for the selected clips")
                .accessibilityLabel("Actions for \(selectedItemCount) selected clips")
            }
            Button(role: .destructive, action: requestClear) {
                Label("Clear", systemImage: "trash")
            }
            .disabled(clearableItemCount == 0)
            .help(clearLabel)
            .accessibilityLabel(clearLabel)
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

    private var clearLabel: String {
        keepPinnedOnClear ? "Clear unpinned clips" : "Clear all clips"
    }
}

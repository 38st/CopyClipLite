import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""

    private var visibleItems: [ClipboardItem] {
        store.visibleItems(matching: searchText)
    }

    private var pinnedItems: [ClipboardItem] {
        visibleItems.filter(\.isPinned)
    }

    private var recentItems: [ClipboardItem] {
        visibleItems.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            searchField
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            content

            Divider()

            footer
        }
        .background(.regularMaterial)
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

                Text(store.isMonitoringEnabled ? "Monitoring clipboard" : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Open window")

            Button {
                store.isMonitoringEnabled.toggle()
            } label: {
                Image(systemName: store.isMonitoringEnabled ? "pause.circle" : "play.circle")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(store.isMonitoringEnabled ? "Pause monitoring" : "Resume monitoring")

            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Settings")
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
                .onSubmit {
                    if let firstItem = visibleItems.first {
                        store.copy(firstItem)
                    }
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
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.72))
        )
    }

    @ViewBuilder
    private var content: some View {
        if visibleItems.isEmpty {
            EmptyHistoryView(isSearching: !searchText.isEmpty)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !pinnedItems.isEmpty {
                        SectionHeader(title: "Pinned")

                        ForEach(pinnedItems) { item in
                            ClipboardItemRow(
                                item: item,
                                isCopied: store.lastCopiedID == item.id,
                                copy: { store.copy(item) },
                                togglePin: { store.togglePin(item) },
                                delete: { store.delete(item) }
                            )
                        }
                    }

                    if !recentItems.isEmpty {
                        SectionHeader(title: pinnedItems.isEmpty ? "Recent" : "History")

                        ForEach(recentItems) { item in
                            ClipboardItemRow(
                                item: item,
                                isCopied: store.lastCopiedID == item.id,
                                copy: { store.copy(item) },
                                togglePin: { store.togglePin(item) },
                                delete: { store.delete(item) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(store.historySummaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .layoutPriority(1)

            Spacer()

            Button(role: .destructive) {
                store.clearHistory()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

private struct EmptyHistoryView: View {
    let isSearching: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isSearching ? "magnifyingglass" : "clipboard")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)

            Text(isSearching ? "No matches" : "Copy something to start")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

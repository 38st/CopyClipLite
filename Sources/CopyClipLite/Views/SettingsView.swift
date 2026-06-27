import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @State private var transferMessage: String?
    @State private var transferError: String?

    private var historyLimit: Binding<Int> {
        Binding(
            get: { store.historyLimit },
            set: { store.setHistoryLimit($0) }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }

    private var monitoringEnabled: Binding<Bool> {
        Binding(
            get: { store.isMonitoringEnabled },
            set: { store.setMonitoringEnabled($0) }
        )
    }

    var body: some View {
        Form {
            Section("History") {
                Stepper(value: historyLimit, in: 10...200, step: 10) {
                    LabeledContent("Items", value: "\(store.historyLimit)")
                }

                Picker("Auto-clear unpinned clips", selection: $store.retentionPolicy) {
                    ForEach(ClipboardRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Pinned clips", value: "Never auto-clear")

                Toggle("Keep pinned items when clearing", isOn: $store.keepPinnedOnClear)

                Toggle("Clear unpinned history when quitting", isOn: $store.clearUnpinnedOnQuit)
            }

            Section("Clipboard") {
                Toggle("Monitor clipboard", isOn: monitoringEnabled)

                LabeledContent("Status", value: store.monitoringStatusText)

                Menu {
                    ForEach(ClipboardPauseDuration.allCases) { duration in
                        Button(duration.title) {
                            store.pauseMonitoring(for: duration)
                        }
                    }
                } label: {
                    Label("Pause Monitoring", systemImage: "pause.circle")
                }

                LabeledContent("Global hotkey", value: hotkeyController.statusText)
            }

            Section("Ignored Apps") {
                if store.ignoredApplications.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.ignoredApplications) { application in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.name)
                                Text(application.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                store.removeIgnoredApplication(application)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }

                Button {
                    addIgnoredApplication()
                } label: {
                    Label("Add App", systemImage: "plus")
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: launchAtLogin)

                LabeledContent("Status", value: loginItem.statusText)

                if loginItem.needsApproval {
                    Button {
                        loginItem.openLoginItemsSettings()
                    } label: {
                        Label("Open Login Items Settings", systemImage: "gear")
                    }
                }

                if let errorMessage = loginItem.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Data") {
                LabeledContent("Stored at") {
                    Text(store.storageLocation.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.storageLocation])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                HStack {
                    Button {
                        exportHistory()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        importHistory()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }

                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let transferError {
                    Text(transferError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            loginItem.refresh()
        }
    }

    private func addIgnoredApplication() {
        guard let application = ApplicationPickerPanel.chooseApplication() else {
            return
        }

        store.addIgnoredApplication(application)
    }

    private func exportHistory() {
        transferMessage = nil
        transferError = nil

        guard let url = ClipboardHistoryTransferPanel.exportDestinationURL(
            defaultFileName: "CopyClip-Lite-History.json"
        ) else {
            return
        }

        do {
            try store.exportHistory(to: url)
            transferMessage = "Exported history"
        } catch {
            transferError = error.localizedDescription
        }
    }

    private func importHistory() {
        transferMessage = nil
        transferError = nil

        guard let url = ClipboardHistoryTransferPanel.importSourceURL() else {
            return
        }

        do {
            try store.importHistory(from: url)
            transferMessage = "Imported history"
        } catch {
            transferError = error.localizedDescription
        }
    }
}

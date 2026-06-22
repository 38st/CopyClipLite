import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController

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
                Toggle("Monitor clipboard", isOn: $store.isMonitoringEnabled)
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
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            loginItem.refresh()
        }
    }
}

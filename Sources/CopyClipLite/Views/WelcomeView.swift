import AppKit
import SwiftUI

enum WelcomeContent {
    static func hotkeyDetail(isRegistered: Bool, displayString: String) -> String {
        if isRegistered {
            return "Use the menu bar or press \(displayString)."
        }
        return "Use the menu bar. The global shortcut is currently unavailable."
    }
}

struct WelcomeView: View {
    @ObservedObject var hotkeyController: GlobalHotkeyController
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            VStack(spacing: 6) {
                Text("CopyClip Lite")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Clipboard history for macOS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomeRow(
                    systemImage: "menubar.rectangle",
                    title: "Open it instantly",
                    detail: hotkeyDetail
                )
                WelcomeRow(
                    systemImage: "lock.doc",
                    title: "Stored only on this Mac",
                    detail: "The last 50 unpinned clips auto-clear after 7 days."
                )
                WelcomeRow(
                    systemImage: "eye.slash",
                    title: "Protect sensitive copies",
                    detail: "Concealed clipboard data is skipped; add source exclusions in Settings."
                )
                WelcomeRow(
                    systemImage: "externaldrive.badge.exclamationmark",
                    title: "Protected by your Mac login",
                    detail: "History uses private file permissions but is not separately encrypted. FileVault is recommended."
                )
            }
            .padding(.vertical, 4)

            Spacer(minLength: 12)

            Button(action: continueAction) {
                Text("Start Using CopyClip Lite")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("CopyClip Lite keeps running from the menu bar without a Dock icon. You can pause or clear monitoring at any time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var hotkeyDetail: String {
        WelcomeContent.hotkeyDetail(
            isRegistered: hotkeyController.isRegistered,
            displayString: hotkeyController.config.displayString
        )
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

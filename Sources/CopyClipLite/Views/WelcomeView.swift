import AppKit
import SwiftUI

struct WelcomeView: View {
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

            VStack(alignment: .leading, spacing: 12) {
                WelcomeRow(systemImage: "menubar.rectangle", title: "Menu Bar")
                WelcomeRow(systemImage: "lock.doc", title: "Local History")
                WelcomeRow(systemImage: "pin", title: "Pinned Clips")
            }
            .padding(.vertical, 4)

            Spacer(minLength: 12)

            Button(action: continueAction) {
                Text("Start Using CopyClip Lite")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("CopyClip Lite keeps running from the menu bar. Close this window any time.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)

            Text(title)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}

import SwiftUI

struct IssueBanner: View {
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

struct SectionHeader: View {
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

enum EmptyHistoryReason {
    case noHistory
    case noMatches
    case noTextClips
    case noImageClips
    case noLinkClips
    case noPinnedClips

    var systemImage: String {
        switch self {
        case .noHistory: "clipboard"
        case .noMatches: "magnifyingglass"
        case .noTextClips: "text.alignleft"
        case .noImageClips: "photo"
        case .noLinkClips: "link"
        case .noPinnedClips: "pin"
        }
    }

    var title: String {
        switch self {
        case .noHistory: "Copy something to start"
        case .noMatches: "No matches"
        case .noTextClips: "No text clips"
        case .noImageClips: "No image clips"
        case .noLinkClips: "No files or links"
        case .noPinnedClips: "No pinned clips"
        }
    }

    var message: String {
        switch self {
        case .noHistory: "Recent clips will appear here."
        case .noMatches: "Try a different search or filter."
        case .noTextClips: "Text clips will appear here."
        case .noImageClips: "Image clips will appear here."
        case .noLinkClips: "Files and links you copy will appear here."
        case .noPinnedClips: "Pinned clips will stay at the top."
        }
    }
}

struct EmptyHistoryView: View {
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

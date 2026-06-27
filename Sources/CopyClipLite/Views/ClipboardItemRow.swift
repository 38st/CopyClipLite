import AppKit
import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: copy) {
                HStack(alignment: .top, spacing: 10) {
                    if item.isImage {
                        ClipboardImageThumbnail(data: item.image?.data)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.previewText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if isCopied {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        HStack(spacing: 6) {
                            Text(item.metadataText)

                            Text("·")

                            Text(item.lastCopiedDescription)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")

            VStack(spacing: 6) {
                Button(action: togglePin) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin" : "Pin")

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45))
        )
        .contextMenu {
            Button("Copy", action: copy)
            Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
    }
}

private struct ClipboardImageThumbnail: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .separatorColor).opacity(0.2))

            if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
        )
    }

    private var nsImage: NSImage? {
        guard let data else {
            return nil
        }

        return NSImage(data: data)
    }
}

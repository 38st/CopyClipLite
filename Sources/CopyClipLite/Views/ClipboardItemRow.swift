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

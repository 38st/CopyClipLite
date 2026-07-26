import AppKit
import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let rowID: ClipboardItem.ID
    let isCopied: Bool
    let isSelected: Bool
    let thumbnailData: Data?
    let activate: () -> Void
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void
    let ignoreApplication: (() -> Void)?
    let transform: ((TextTransformation) -> Void)?
    let dragProvider: () -> NSItemProvider

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: activate) {
                HStack(alignment: .top, spacing: 10) {
                    if item.isImage {
                        ClipboardImageThumbnail(data: thumbnailData)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.previewText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if item.hasRichText {
                                Text("RTF")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            }

                            if isCopied {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        HStack(spacing: 6) {
                            Text(item.metadataText)

                            Text("·")

                            TimelineView(.periodic(from: .now, by: 10)) { _ in
                                Text(item.lastCopiedDescription)
                            }
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
            .help("Use clip")
            .accessibilityLabel(item.previewText)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint("Activate to use this clip.")
            .accessibilityAction(named: "Copy clip", copy)
            .accessibilityAction(
                named: item.isPinned ? "Unpin clip" : "Pin clip",
                togglePin
            )
            .accessibilityAction(named: "Delete clip", delete)

            VStack(spacing: 6) {
                Button(action: togglePin) {
                    Label(
                        item.isPinned ? "Unpin clip" : "Pin clip",
                        systemImage: item.isPinned ? "pin.fill" : "pin"
                    )
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin" : "Pin")
                .accessibilityHidden(true)

                Button(role: .destructive, action: delete) {
                    Label("Delete clip", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Delete")
                .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor)
        )
        .contextMenu {
            Button("Copy", action: copy)
            Button(item.isPinned ? "Unpin" : "Pin", action: togglePin)

            if item.contentKind == .text, let transform {
                Menu("Transform & Copy") {
                    ForEach(TextTransformation.allCases) { transformation in
                        Button(transformation.title) {
                            transform(transformation)
                        }
                    }
                }
            }

            if let ignoreApplication, let sourceApplication = item.sourceApplication {
                Button("Ignore \(sourceApplication.name)", action: ignoreApplication)
            }
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .id(rowID)
        .onDrag(dragProvider)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }

        return Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.62)
        }

        return Color(nsColor: .separatorColor).opacity(0.45)
    }

    private var accessibilityValue: String {
        [isSelected ? "Selected" : nil, isCopied ? "Copied" : nil, item.metadataText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct ClipboardImageThumbnail: View {
    let data: Data?
    @State private var cachedImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .separatorColor).opacity(0.2))

            if let cachedImage {
                Image(nsImage: cachedImage)
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
        .onAppear {
            if cachedImage == nil, let data {
                cachedImage = NSImage(data: data)
            }
        }
        .onChange(of: data) { _, newData in
            cachedImage = newData.flatMap(NSImage.init(data:))
        }
    }
}

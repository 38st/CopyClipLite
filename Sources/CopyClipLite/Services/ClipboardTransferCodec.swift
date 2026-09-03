import Foundation

enum ClipboardTransferCodec {
    static func itemLimitExceededReason(itemCount: Int) -> String {
        let actualCount = groupedDecimal(itemCount)
        let limit = groupedDecimal(ClipboardStorage.maximumImportedItems)
        return "\(actualCount) clips exceeds the \(limit)-clip export limit. "
            + "Unpin or delete clips, then export again."
    }

    private static func groupedDecimal(_ value: Int) -> String {
        let digits = Array(String(value))
        var groups: [String] = []
        var end = digits.count
        while end > 0 {
            let start = max(0, end - 3)
            groups.append(String(digits[start..<end]))
            end = start
        }
        return groups.reversed().joined(separator: ",")
    }

    static func encode(_ items: [ClipboardItem]) throws -> Data {
        try validateForExport(items)
        let document = ClipboardTransferDocument(items: items.map(ClipboardTransferItem.init))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= ClipboardStorage.maximumImportBytes else {
            throw ClipboardStorageError.incompatibleExport(
                "the encoded file would exceed \(ByteCountFormatter.string(fromByteCount: Int64(ClipboardStorage.maximumImportBytes), countStyle: .file))"
            )
        }
        return data
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> [ClipboardItem] {
        guard data.count <= ClipboardStorage.maximumImportBytes else {
            throw ClipboardStorageError.importTooLarge
        }

        let decoder = JSONDecoder()
        let transferItems: [ClipboardTransferItem]
        let isCurrentFormat: Bool
        let transferRoot: Any
        do {
            transferRoot = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClipboardStorageError.invalidImportedItem("the transfer JSON is malformed")
        }

        if let documentObject = transferRoot as? [String: Any] {
            guard let format = documentObject["format"] as? String,
                  format == "CopyClipLite" else {
                throw ClipboardStorageError.invalidImportedItem("the transfer format identifier is invalid")
            }
            guard let version = documentObject["version"] as? Int else {
                throw ClipboardStorageError.invalidImportedItem(
                    "the transfer version is missing or invalid"
                )
            }
            guard version == ClipboardTransferDocument.currentVersion else {
                throw ClipboardStorageError.unsupportedTransferVersion(version)
            }
            guard documentObject["items"] is [Any] else {
                throw ClipboardStorageError.invalidImportedItem(
                    "the transfer items field is missing or malformed"
                )
            }
            do {
                transferItems = try decoder.decode(ClipboardTransferDocument.self, from: data).items
            } catch {
                throw currentDocumentDecodingError(error)
            }
            isCurrentFormat = true
        } else if transferRoot is [Any] {
            transferItems = try decoder.decode([ClipboardTransferItem].self, from: data)
            isCurrentFormat = false
        } else {
            throw ClipboardStorageError.invalidImportedItem(
                "the transfer root must be a current-format object or legacy array"
            )
        }

        var items = try transferItems.map {
            try domainItem(from: $0, isCurrentFormat: isCurrentFormat, now: now)
        }
        try validateImportedItems(items)
        let latestAllowedDate = now.addingTimeInterval(5 * 60)
        for index in items.indices {
            let boundedCreatedAt = min(items[index].createdAt, latestAllowedDate)
            let boundedLastCopiedAt = min(items[index].lastCopiedAt, latestAllowedDate)
            // Legacy raw-array exports did not enforce timestamp ordering.
            // Normalize them into the invariant required by the current
            // format so every successful legacy import can be re-exported.
            items[index].createdAt = min(boundedCreatedAt, boundedLastCopiedAt)
            items[index].lastCopiedAt = boundedLastCopiedAt
            if var image = items[index].image, let imageData = image.data {
                do {
                    image = try ClipboardImageProcessor.process(
                        ClipboardImageCandidate(data: imageData, isPNG: true)
                    )
                } catch {
                    throw ClipboardStorageError.invalidImportedItem(error.localizedDescription)
                }
                items[index].image = image
            }
        }
        return items
    }

    static func validateImportedItems(_ items: [ClipboardItem]) throws {
        guard items.count <= ClipboardStorage.maximumImportedItems else {
            throw ClipboardStorageError.tooManyImportedItems
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw ClipboardStorageError.duplicateImportedItem
        }

        for item in items {
            guard item.text.count <= ClipboardStorage.maximumImportedTextCharacters else {
                throw ClipboardStorageError.invalidImportedItem("text exceeds 20,000 characters")
            }
            guard (1...1_000_000).contains(item.copyCount) else {
                throw ClipboardStorageError.invalidImportedItem("copy count is outside the supported range")
            }
            guard item.rtfData?.count ?? 0 <= ClipboardStorage.maximumImportedRichTextBytes,
                  item.htmlData?.count ?? 0 <= ClipboardStorage.maximumImportedRichTextBytes else {
                throw ClipboardStorageError.invalidImportedItem("rich text data is too large")
            }

            switch item.contentKind {
            case .text:
                guard item.image == nil else {
                    throw ClipboardStorageError.invalidImportedItem("a text clip contains image data")
                }
                guard item.text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
                    throw ClipboardStorageError.invalidImportedItem("a text clip is blank")
                }
            case .image:
                guard let image = item.image else {
                    throw ClipboardStorageError.missingImageData
                }
                guard image.fileName == nil, image.thumbnailFileName == nil else {
                    throw ClipboardStorageError.invalidImportedItem("external image paths are not allowed")
                }
                guard let data = image.data, !data.isEmpty else {
                    throw ClipboardStorageError.missingImageData
                }
                guard data.count <= ClipboardStorage.maximumImportedImageBytes,
                      image.thumbnailData?.count ?? 0 <= ClipboardStorage.maximumImportedImageBytes else {
                    throw ClipboardStorageError.invalidImportedItem("image data is too large")
                }
            }
        }
    }

    private static func validateForExport(_ items: [ClipboardItem]) throws {
        guard items.count <= ClipboardStorage.maximumImportedItems else {
            throw ClipboardStorageError.incompatibleExport(
                itemLimitExceededReason(itemCount: items.count)
            )
        }
        do {
            try validateImportedItems(items)
            let latestAllowedDate = Date().addingTimeInterval(5 * 60)
            guard items.allSatisfy({
                $0.createdAt <= $0.lastCopiedAt
                    && $0.createdAt <= latestAllowedDate
                    && $0.lastCopiedAt <= latestAllowedDate
            }) else {
                throw ClipboardStorageError.invalidImportedItem(
                    "timestamps are invalid or too far in the future"
                )
            }
        } catch let error as ClipboardStorageError {
            throw ClipboardStorageError.incompatibleExport(error.localizedDescription)
        }
    }

    private static func domainItem(
        from transfer: ClipboardTransferItem,
        isCurrentFormat: Bool,
        now: Date
    ) throws -> ClipboardItem {
        if isCurrentFormat {
            guard transfer.id != nil else {
                throw ClipboardStorageError.invalidImportedItem("the clip identifier is missing")
            }
            guard transfer.text != nil else {
                throw ClipboardStorageError.invalidImportedItem("the clip text field is missing")
            }
            guard transfer.contentKind != nil else {
                throw ClipboardStorageError.invalidImportedItem("the content kind is missing")
            }
            guard transfer.createdAt != nil, transfer.lastCopiedAt != nil else {
                throw ClipboardStorageError.invalidImportedItem("clip timestamps are missing")
            }
            guard transfer.isPinned != nil else {
                throw ClipboardStorageError.invalidImportedItem("the pinned state is missing")
            }
            guard transfer.copyCount != nil else {
                throw ClipboardStorageError.invalidImportedItem("the copy count is missing")
            }
        }

        let kind: ClipboardContentKind
        if let rawKind = transfer.contentKind {
            guard let decodedKind = ClipboardContentKind(rawValue: rawKind) else {
                throw ClipboardStorageError.invalidImportedItem("unknown content kind “\(rawKind)”")
            }
            kind = decodedKind
        } else {
            kind = transfer.image == nil ? .text : .image
        }

        let id = transfer.id ?? UUID()
        let text = transfer.text ?? ""
        let createdAt = transfer.createdAt ?? now
        let lastCopiedAt = transfer.lastCopiedAt ?? createdAt
        let copyCount = transfer.copyCount ?? 1
        if isCurrentFormat {
            let latestAllowedDate = now.addingTimeInterval(5 * 60)
            guard createdAt <= lastCopiedAt,
                  createdAt <= latestAllowedDate,
                  lastCopiedAt <= latestAllowedDate else {
                throw ClipboardStorageError.invalidImportedItem(
                    "timestamps are invalid or too far in the future"
                )
            }
        }

        switch kind {
        case .text:
            guard transfer.image == nil else {
                throw ClipboardStorageError.invalidImportedItem("a text clip contains image data")
            }
            return ClipboardItem(
                id: id,
                text: text,
                rtfData: transfer.rtfData,
                htmlData: transfer.htmlData,
                createdAt: createdAt,
                lastCopiedAt: lastCopiedAt,
                isPinned: transfer.isPinned ?? false,
                copyCount: copyCount,
                sourceApplication: transfer.sourceApplication
            )
        case .image:
            guard let transferImage = transfer.image else {
                throw ClipboardStorageError.missingImageData
            }
            guard transferImage.fileName == nil, transferImage.thumbnailFileName == nil else {
                throw ClipboardStorageError.invalidImportedItem("external image paths are not allowed")
            }
            guard let data = transferImage.data, !data.isEmpty else {
                throw ClipboardStorageError.missingImageData
            }
            if isCurrentFormat {
                guard let width = transferImage.width, width > 0,
                      let height = transferImage.height, height > 0 else {
                    throw ClipboardStorageError.invalidImportedItem("image dimensions must be positive")
                }
                guard let byteCount = transferImage.byteCount, byteCount == data.count else {
                    throw ClipboardStorageError.invalidImportedItem(
                        "image byte count does not match its data"
                    )
                }
                guard let contentHash = transferImage.contentHash,
                      contentHash == ClipboardImageProcessor.contentHash(for: data) else {
                    throw ClipboardStorageError.invalidImportedItem(
                        "image content hash does not match its data"
                    )
                }
            }
            return ClipboardItem(
                id: id,
                text: text,
                image: ClipboardImagePayload(
                    data: data,
                    thumbnailData: transferImage.thumbnailData,
                    width: transferImage.width ?? 0,
                    height: transferImage.height ?? 0,
                    byteCount: transferImage.byteCount,
                    contentHash: transferImage.contentHash
                ),
                createdAt: createdAt,
                lastCopiedAt: lastCopiedAt,
                isPinned: transfer.isPinned ?? false,
                copyCount: copyCount,
                sourceApplication: transfer.sourceApplication
            )
        }
    }

    private static func currentDocumentDecodingError(_ error: Error) -> ClipboardStorageError {
        let codingPath: [CodingKey]
        switch error {
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context),
             let DecodingError.dataCorrupted(context):
            codingPath = context.codingPath
        case let DecodingError.keyNotFound(key, context):
            codingPath = context.codingPath + [key]
        default:
            return .invalidImportedItem("the current transfer document is malformed")
        }
        let fieldPath = codingPath.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                if !result.isEmpty { result += "." }
                result += key.stringValue
            }
        }
        guard !fieldPath.isEmpty else {
            return .invalidImportedItem("the current transfer document is malformed")
        }
        return .invalidImportedItem(
            "the current transfer field “\(fieldPath)” is malformed"
        )
    }
}

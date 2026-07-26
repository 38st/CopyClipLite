import AppKit
import Foundation

enum ClipboardPasteboardValue: Sendable, Equatable {
    case string(String)
    case data(Data)
}

struct ClipboardPasteboardRepresentation: Sendable, Equatable {
    let type: String
    let value: ClipboardPasteboardValue

    init(_ type: NSPasteboard.PasteboardType, value: ClipboardPasteboardValue) {
        self.type = type.rawValue
        self.value = value
    }
}

struct ClipboardPasteboardWriteRequest: Sendable, Equatable {
    let required: [ClipboardPasteboardRepresentation]
    let optional: [ClipboardPasteboardRepresentation]
}

enum ClipboardPasteboardWriteResult: Sendable, Equatable {
    case success
    case degraded(optionalTypes: [String])
    case failure

    var wroteRequiredRepresentations: Bool {
        self != .failure
    }
}

protocol ClipboardPasteboardWriting: Sendable {
    func write(_ request: ClipboardPasteboardWriteRequest) -> ClipboardPasteboardWriteResult
}

final class SystemClipboardPasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func write(_ request: ClipboardPasteboardWriteRequest) -> ClipboardPasteboardWriteResult {
        let item = NSPasteboardItem()
        guard request.required.allSatisfy({ set($0, on: item) }) else {
            return .failure
        }

        var skippedOptionalTypes: [String] = []
        for representation in request.optional where !set(representation, on: item) {
            skippedOptionalTypes.append(representation.type)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            return .failure
        }

        return skippedOptionalTypes.isEmpty
            ? .success
            : .degraded(optionalTypes: skippedOptionalTypes)
    }

    private func set(
        _ representation: ClipboardPasteboardRepresentation,
        on item: NSPasteboardItem
    ) -> Bool {
        let type = NSPasteboard.PasteboardType(representation.type)
        switch representation.value {
        case let .string(value):
            return item.setString(value, forType: type)
        case let .data(value):
            return item.setData(value, forType: type)
        }
    }
}

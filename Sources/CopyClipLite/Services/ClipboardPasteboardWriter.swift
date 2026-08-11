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

protocol ClipboardPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    @discardableResult func clearPasteboardContents() -> Int
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool
}

extension NSPasteboard: ClipboardPasteboardAccess {
    func clearPasteboardContents() -> Int {
        clearContents()
    }

    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        writeObjects(items)
    }
}

final class SystemClipboardPasteboardWriter: ClipboardPasteboardWriting, @unchecked Sendable {
    private struct PreparedItem {
        let item: NSPasteboardItem
        let writtenRequest: ClipboardPasteboardWriteRequest
        let skippedOptionalTypes: [String]
    }

    private struct OwnedRollbackSnapshot {
        let request: ClipboardPasteboardWriteRequest
        let changeCount: Int
    }

    private static let defaultMaximumRollbackBytes = 24 * 1_024 * 1_024
    private static let maximumRollbackRepresentations = 8

    private let pasteboard: any ClipboardPasteboardAccess
    private let maximumRollbackBytes: Int
    private var ownedRollbackSnapshot: OwnedRollbackSnapshot?

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        self.maximumRollbackBytes = Self.defaultMaximumRollbackBytes
    }

    init(
        pasteboard: any ClipboardPasteboardAccess,
        maximumRollbackBytes: Int? = nil
    ) {
        self.pasteboard = pasteboard
        self.maximumRollbackBytes = max(
            maximumRollbackBytes ?? Self.defaultMaximumRollbackBytes,
            0
        )
    }

    func write(_ request: ClipboardPasteboardWriteRequest) -> ClipboardPasteboardWriteResult {
        guard let prepared = prepare(request) else {
            return .failure
        }

        // AppKit has no size metadata for promised pasteboard values, so reading an
        // arbitrary previous owner here could materialize unbounded data. Retain only
        // a bounded request that this writer successfully placed on the pasteboard,
        // and restore it only while its change count proves ownership is unchanged.
        let rollbackSnapshot = ownedRollbackSnapshot.flatMap { snapshot in
            pasteboard.changeCount == snapshot.changeCount ? snapshot : nil
        }
        pasteboard.clearPasteboardContents()
        guard pasteboard.writePasteboardItems([prepared.item]) else {
            ownedRollbackSnapshot = nil
            restore(snapshot: rollbackSnapshot)
            return .failure
        }

        rememberForRollbackIfBounded(prepared.writtenRequest)
        return prepared.skippedOptionalTypes.isEmpty
            ? .success
            : .degraded(optionalTypes: prepared.skippedOptionalTypes)
    }

    private func prepare(_ request: ClipboardPasteboardWriteRequest) -> PreparedItem? {
        let item = NSPasteboardItem()
        guard request.required.allSatisfy({ set($0, on: item) }) else {
            return nil
        }

        var skippedOptionalTypes: [String] = []
        var writtenOptional: [ClipboardPasteboardRepresentation] = []
        for representation in request.optional {
            if set(representation, on: item) {
                writtenOptional.append(representation)
            } else {
                skippedOptionalTypes.append(representation.type)
            }
        }

        return PreparedItem(
            item: item,
            writtenRequest: ClipboardPasteboardWriteRequest(
                required: request.required,
                optional: writtenOptional
            ),
            skippedOptionalTypes: skippedOptionalTypes
        )
    }

    private func restore(snapshot: OwnedRollbackSnapshot?) {
        guard let snapshot, let prepared = prepare(snapshot.request) else {
            return
        }
        pasteboard.clearPasteboardContents()
        guard pasteboard.writePasteboardItems([prepared.item]) else { return }
        rememberForRollbackIfBounded(prepared.writtenRequest)
    }

    private func rememberForRollbackIfBounded(_ request: ClipboardPasteboardWriteRequest) {
        guard isBoundedForRollback(request) else {
            ownedRollbackSnapshot = nil
            return
        }
        ownedRollbackSnapshot = OwnedRollbackSnapshot(
            request: request,
            changeCount: pasteboard.changeCount
        )
    }

    private func isBoundedForRollback(_ request: ClipboardPasteboardWriteRequest) -> Bool {
        let representations = request.required + request.optional
        guard representations.count <= Self.maximumRollbackRepresentations else {
            return false
        }

        var totalBytes = 0
        for representation in representations {
            let byteCount: Int
            switch representation.value {
            case let .string(value):
                byteCount = value.utf8.count
            case let .data(value):
                byteCount = value.count
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard !overflow, nextTotal <= maximumRollbackBytes else {
                return false
            }
            totalBytes = nextTotal
        }
        return true
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

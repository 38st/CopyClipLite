import AppKit
import XCTest
@testable import CopyClipLite

private final class FaultInjectingPasteboard: ClipboardPasteboardAccess {
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private(set) var attemptedStrings: [String?] = []
    private(set) var currentString: String?
    var writeResults: [Bool] = []

    func clearPasteboardContents() -> Int {
        clearCount += 1
        changeCount += 1
        currentString = nil
        return changeCount
    }

    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        let string = items.first?.string(forType: .string)
        attemptedStrings.append(string)
        let result = writeResults.isEmpty ? true : writeResults.removeFirst()
        if result {
            currentString = string
        }
        return result
    }

    func simulateExternalChange(to string: String) {
        changeCount += 1
        currentString = string
    }
}

final class ClipboardPasteboardWriterTests: XCTestCase {
    func testFailedWriteRestoresLastBoundedClipboardOwnedByWriter() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false, true]
        let writer = SystemClipboardPasteboardWriter(pasteboard: pasteboard)

        XCTAssertEqual(writer.write(request(text: "previous")), .success)
        XCTAssertEqual(writer.write(request(text: "replacement")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["previous", "replacement", "previous"])
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.clearCount, 3)
    }

    func testFailedWriteDoesNotMaterializeOrOverwriteSnapshotAfterExternalChange() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false]
        let writer = SystemClipboardPasteboardWriter(pasteboard: pasteboard)

        XCTAssertEqual(writer.write(request(text: "owned")), .success)
        pasteboard.simulateExternalChange(to: "external")
        XCTAssertEqual(writer.write(request(text: "replacement")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["owned", "replacement"])
        XCTAssertNil(pasteboard.currentString)
        XCTAssertEqual(pasteboard.clearCount, 2)
    }

    func testOversizedOwnedClipboardIsNotRetainedForRollback() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false]
        let writer = SystemClipboardPasteboardWriter(
            pasteboard: pasteboard,
            maximumRollbackBytes: 4
        )

        XCTAssertEqual(writer.write(request(text: "12345")), .success)
        XCTAssertEqual(writer.write(request(text: "new")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["12345", "new"])
        XCTAssertNil(pasteboard.currentString)
    }

    private func request(text: String) -> ClipboardPasteboardWriteRequest {
        ClipboardPasteboardWriteRequest(
            required: [
                ClipboardPasteboardRepresentation(.string, value: .string(text))
            ],
            optional: []
        )
    }
}

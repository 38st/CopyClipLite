import Foundation
import XCTest

@testable import CopyClipLite

final class ClipboardContentTests: XCTestCase {
    func testTextAndImageTransitionsPreserveValidExclusiveContent() throws {
        var item = ClipboardItem(
            text: "formatted",
            rtfData: Data("rtf".utf8),
            htmlData: Data("html".utf8)
        )
        XCTAssertEqual(item.contentKind, .text)
        XCTAssertNil(item.image)
        XCTAssertNotNil(item.rtfData)

        let image = ClipboardImagePayload(
            data: Data([1, 2, 3]),
            width: 1,
            height: 1
        )
        item.image = image

        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.image, image)
        XCTAssertNil(item.rtfData)
        XCTAssertNil(item.htmlData)

        item.rtfData = Data("ignored".utf8)
        XCTAssertNil(item.rtfData)

        item.image = nil
        XCTAssertEqual(item.contentKind, .text)
        XCTAssertNil(item.image)
        XCTAssertEqual(item.text, "formatted")
    }

    func testCodableKeepsLegacyKeysAndRoundTripsTypedContent() throws {
        let original = ClipboardItem(
            text: "caption",
            image: ClipboardImagePayload(
                data: Data([4, 5, 6]),
                width: 2,
                height: 3
            )
        )
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["contentKind"] as? String, "image")
        XCTAssertEqual(object["text"] as? String, "caption")
        XCTAssertNotNil(object["image"])

        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.contentKind, .image)
    }

    func testLegacyContradictoryRecordNormalizesAtDecodeBoundary() throws {
        let data = Data(
            """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "text": "legacy",
              "contentKind": "image",
              "createdAt": 0,
              "lastCopiedAt": 0,
              "isPinned": false,
              "copyCount": 1
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        XCTAssertEqual(decoded.contentKind, .text)
        XCTAssertNil(decoded.image)
        XCTAssertEqual(decoded.text, "legacy")
    }
}

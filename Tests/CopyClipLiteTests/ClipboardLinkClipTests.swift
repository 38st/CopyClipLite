import AppKit
import Foundation
import XCTest

@testable import CopyClipLite

final class ClipboardLinkClipTests: XCTestCase {

    // MARK: Capture

    func testNonImageFileURLBecomesAFileClip() throws {
        let pasteboard = makePasteboard()
        let fileURL = URL(fileURLWithPath: "/Users/someone/Documents/quarterly-report.pdf")
        XCTAssertTrue(pasteboard.setString(fileURL.absoluteString, forType: .fileURL))

        let link = try XCTUnwrap(ClipboardCaptureReader.link(from: pasteboard))

        XCTAssertTrue(link.isFileURL)
        XCTAssertEqual(link.url, fileURL)
        XCTAssertEqual(link.title, "quarterly-report.pdf")
        XCTAssertEqual(link.subtitle, "/Users/someone/Documents")
        XCTAssertEqual(link.displayText, "/Users/someone/Documents/quarterly-report.pdf")
    }

    func testImageFileURLIsLeftToTheImagePipeline() {
        let pasteboard = makePasteboard()
        let imageURL = URL(fileURLWithPath: "/Users/someone/Pictures/screenshot.png")
        XCTAssertTrue(pasteboard.setString(imageURL.absoluteString, forType: .fileURL))

        // The image pipeline normalizes it to PNG so the clip outlives the file.
        XCTAssertNil(ClipboardCaptureReader.link(from: pasteboard))
        XCTAssertNotNil(ClipboardCaptureReader.image(from: pasteboard))
    }

    func testWebURLBecomesALinkClipWithItsHost() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(
            pasteboard.setString("https://github.com/38st/CopyClipLite", forType: .URL)
        )

        let link = try XCTUnwrap(ClipboardCaptureReader.link(from: pasteboard))

        XCTAssertFalse(link.isFileURL)
        XCTAssertEqual(link.subtitle, "github.com")
        XCTAssertEqual(link.displayText, "https://github.com/38st/CopyClipLite")
    }

    func testNonWebSchemeIsNotCapturedAsALink() {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.setString("javascript:alert(1)", forType: .URL))

        XCTAssertNil(ClipboardCaptureReader.link(from: pasteboard))
    }

    // MARK: History behaviour

    func testRecordingTheSameURLTwiceDeduplicatesAndCounts() {
        let url = URL(string: "https://example.com/a")!
        let first = ClipboardHistoryRules.recordingLink(
            ClipboardLinkContent(url: url, title: nil),
            sourceApplication: nil,
            capturedAt: Date(timeIntervalSince1970: 10),
            in: []
        )
        let second = ClipboardHistoryRules.recordingLink(
            ClipboardLinkContent(url: url, title: nil),
            sourceApplication: nil,
            capturedAt: Date(timeIntervalSince1970: 20),
            in: first
        )

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.copyCount, 2)
        XCTAssertEqual(second.first?.contentKind, .link)
    }

    func testLinksFilterMatchesOnlyLinkClips() {
        let link = ClipboardItem(
            link: ClipboardLinkContent(url: URL(string: "https://example.com")!, title: nil)
        )
        let text = ClipboardItem(text: "plain")

        XCTAssertTrue(ClipboardContentFilter.links.matches(link))
        XCTAssertFalse(ClipboardContentFilter.links.matches(text))
        XCTAssertFalse(ClipboardContentFilter.text.matches(link))
        XCTAssertTrue(ClipboardContentFilter.all.matches(link))
    }

    // MARK: Persistence

    func testLinkClipRoundTripsThroughStorage() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let fileClip = ClipboardItem(
            link: ClipboardLinkContent(
                url: URL(fileURLWithPath: "/tmp/notes.txt"),
                title: "notes.txt"
            )
        )
        let webClip = ClipboardItem(
            link: ClipboardLinkContent(
                url: URL(string: "https://example.com/page")!,
                title: "Example"
            )
        )
        try storage.saveValidated([fileClip, webClip])

        let loaded = try storage.loadResult().get()
        let loadedFile = try XCTUnwrap(loaded.first { $0.id == fileClip.id })
        let loadedWeb = try XCTUnwrap(loaded.first { $0.id == webClip.id })

        XCTAssertEqual(loadedFile.contentKind, .link)
        XCTAssertTrue(loadedFile.isFileClip)
        XCTAssertEqual(loadedFile.linkURL, URL(fileURLWithPath: "/tmp/notes.txt"))
        XCTAssertEqual(loadedFile.link?.title, "notes.txt")
        XCTAssertFalse(loadedWeb.isFileClip)
        XCTAssertEqual(loadedWeb.link?.title, "Example")
    }

    func testLinkClipRoundTripsThroughExportAndImport() throws {
        let clip = ClipboardItem(
            link: ClipboardLinkContent(
                url: URL(string: "https://example.com/page?q=1")!,
                title: "Example"
            )
        )

        let encoded = try ClipboardTransferCodec.encode([clip])
        let decoded = try ClipboardTransferCodec.decode(encoded)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.contentKind, .link)
        XCTAssertEqual(decoded.first?.linkURL, URL(string: "https://example.com/page?q=1"))
        XCTAssertEqual(decoded.first?.link?.title, "Example")
    }

    func testImportRejectsUnsupportedLinkSchemes() throws {
        let document = Data(
            """
            {
              "format":"CopyClipLite",
              "version":1,
              "items":[
                {
                  "id":"00000000-0000-0000-0000-000000000001",
                  "text":"javascript:alert(1)",
                  "contentKind":"link",
                  "linkURL":"javascript:alert(1)",
                  "createdAt":0,
                  "lastCopiedAt":0,
                  "isPinned":false,
                  "copyCount":1
                }
              ]
            }
            """.utf8
        )

        XCTAssertThrowsError(try ClipboardTransferCodec.decode(document)) { error in
            guard case let ClipboardStorageError.invalidImportedItem(reason) = error else {
                return XCTFail("Expected an invalid imported item, got \(error)")
            }
            XCTAssertTrue(reason.contains("unsupported URL scheme"), reason)
        }
    }

    func testHistoryWrittenBeforeLinkClipsExistedStillLoads() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","text":"older clip",\
        "contentKind":"text","createdAt":0,"lastCopiedAt":0,"isPinned":false,"copyCount":1}]
        """
        try legacy.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loaded = try storage.loadResult().get()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.contentKind, .text)
        XCTAssertEqual(loaded.first?.text, "older clip")
        XCTAssertNil(loaded.first?.linkURL)
    }

    func testALinkKindWithoutAURLDegradesToText() throws {
        let json = Data(
            #"{"id":"00000000-0000-0000-0000-000000000002","text":"orphan",dummy}"#
                .replacingOccurrences(of: "dummy", with: #""contentKind":"link""#)
                .utf8
        )

        let item = try JSONDecoder().decode(ClipboardItem.self, from: json)

        XCTAssertEqual(item.contentKind, .text)
        XCTAssertEqual(item.text, "orphan")
    }

    // MARK: Helpers

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("CopyClipLite.LinkTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

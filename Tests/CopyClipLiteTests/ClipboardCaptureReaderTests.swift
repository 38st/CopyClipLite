import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

final class ClipboardCaptureReaderTests: XCTestCase {
    func testOversizedRichTextIsNotParsedAndItsWarningIsPreserved() throws {
        let pasteboard = makePasteboard()
        let oversizedRTF = Data(
            repeating: 0x41,
            count: ClipboardStorage.maximumImportedRichTextBytes + 1
        )
        XCTAssertTrue(pasteboard.setData(oversizedRTF, forType: .rtf))

        let result = ClipboardCaptureReader.text(from: pasteboard)

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(
            result.warning,
            "The text was saved without oversized RTF formatting."
        )
    }

    func testInvalidPNGRepresentationFallsBackToValidTIFF() throws {
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.setData(Data("not a png".utf8), forType: .png))
        XCTAssertTrue(pasteboard.setData(try makeTIFFData(width: 4, height: 3), forType: .tiff))

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))
        let payload = try ClipboardImageProcessor.process(candidate)

        XCTAssertEqual(payload.width, 4)
        XCTAssertEqual(payload.height, 3)
    }

    func testFinderFileURLIsSnapshottedWithoutReadingTheFile() throws {
        let pasteboard = makePasteboard()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Missing-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertTrue(pasteboard.setString(missingURL.absoluteString, forType: .fileURL))

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))

        guard case let .fileURL(snapshotURL) = try XCTUnwrap(candidate.sources.first) else {
            return XCTFail("Expected a deferred file URL candidate")
        }
        XCTAssertEqual(snapshotURL, missingURL)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("CopyClipLite.ReaderTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    private func makeTIFFData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

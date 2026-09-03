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
        pasteboard.setData(oversizedRTF, forType: .rtf)

        let result = ClipboardCaptureReader.text(from: pasteboard)

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(
            result.warning,
            "The text was saved without oversized RTF formatting."
        )
    }

    func testInvalidPNGRepresentationFallsBackToValidTIFF() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data("not a png".utf8), forType: .png)
        pasteboard.setData(try makeTIFFData(width: 4, height: 3), forType: .tiff)

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))
        let payload = try ClipboardImageProcessor.process(candidate)

        XCTAssertEqual(payload.width, 4)
        XCTAssertEqual(payload.height, 3)
    }

    func testFinderImageFileURLIsSnapshottedWithoutReadingTheFile() throws {
        let pasteboard = makePasteboard()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Missing-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        pasteboard.setString(missingURL.absoluteString, forType: .fileURL)

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))

        guard case let .fileURL(snapshotURL) = try XCTUnwrap(candidate.sources.first) else {
            return XCTFail("Expected a deferred file URL candidate")
        }
        XCTAssertEqual(snapshotURL, missingURL)
    }

    func testFinderNonImageFileURLIsNotTreatedAsAnImageCandidate() {
        let pasteboard = makePasteboard()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Missing-\(UUID().uuidString).txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        pasteboard.setString(missingURL.absoluteString, forType: .fileURL)

        XCTAssertNil(ClipboardCaptureReader.image(from: pasteboard))
    }

    private func makePasteboard() -> StubCapturePasteboard {
        StubCapturePasteboard()
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

private final class StubCapturePasteboard: ClipboardCapturePasteboard {
    private var values: [NSPasteboard.PasteboardType: Data] = [:]

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        values[dataType]
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        values[dataType].flatMap { String(data: $0, encoding: .utf8) }
    }

    func setData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) {
        values[dataType] = data
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) {
        values[dataType] = Data(string.utf8)
    }
}

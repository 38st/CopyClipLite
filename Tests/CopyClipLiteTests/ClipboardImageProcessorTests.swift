import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

final class ClipboardImageProcessorTests: XCTestCase {
    func testTruncatedPNGIsRejectedEvenWhenMetadataIsReadable() throws {
        let validPNG = try makePNGData(width: 4, height: 5)
        let truncatedPNG = validPNG.prefix(24)

        XCTAssertThrowsError(
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: Data(truncatedPNG), isPNG: true)
            )
        )
    }

    func testOrientationIsNormalizedIntoFullImagePixelsAndDimensions() throws {
        let orientedTIFF = try makeOrientedTIFFData(width: 2, height: 1, orientation: 6)

        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: orientedTIFF, isPNG: false)
        )

        XCTAssertEqual(payload.width, 1)
        XCTAssertEqual(payload.height, 2)
        let imageData = try XCTUnwrap(payload.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 2)
        XCTAssertNotNil(payload.thumbnailData)
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try makeBitmap(width: width, height: height)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeOrientedTIFFData(
        width: Int,
        height: Int,
        orientation: Int
    ) throws -> Data {
        let bitmap = try makeBitmap(width: width, height: height)
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(
                    x == 0 ? .red : .blue,
                    atX: x,
                    y: y
                )
            }
        }
        return bitmap
    }
}

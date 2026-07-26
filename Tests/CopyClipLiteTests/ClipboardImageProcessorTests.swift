import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

private final class ImageProcessingCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

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

    func testEveryEXIFOrientationProducesMatchingFullAndThumbnailPixels() throws {
        for orientation in 2...8 {
            let orientedTIFF = try makeOrientedTIFFData(
                width: 3,
                height: 2,
                orientation: orientation
            )
            let payload = try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: orientedTIFF, isPNG: false)
            )
            let full = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(payload.data))
            )
            let thumbnail = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(payload.thumbnailData))
            )

            XCTAssertEqual(full.pixelsWide, thumbnail.pixelsWide, "orientation \(orientation)")
            XCTAssertEqual(full.pixelsHigh, thumbnail.pixelsHigh, "orientation \(orientation)")
            XCTAssertEqual(payload.width, full.pixelsWide, "orientation \(orientation)")
            XCTAssertEqual(payload.height, full.pixelsHigh, "orientation \(orientation)")
            for y in 0..<full.pixelsHigh {
                for x in 0..<full.pixelsWide {
                    assertSameColor(
                        full.colorAt(x: x, y: y),
                        thumbnail.colorAt(x: x, y: y),
                        orientation: orientation,
                        x: x,
                        y: y
                    )
                }
            }
        }
    }

    func testJPEGDeclaredAsPNGIsRejected() throws {
        let bitmap = try makeBitmap(width: 3, height: 2)
        let jpeg = try XCTUnwrap(
            bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        )

        XCTAssertThrowsError(
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: jpeg, isPNG: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardImageProcessingError,
                .invalidImage
            )
        }
    }

    func testMaximumSupportedImageMeetsLatencyAndResidentGrowthBudgets() async throws {
        let side = 4_096
        XCTAssertEqual(side * side, ClipboardImageProcessor.maximumPixelCount)
        let png = try makeSolidPNGData(width: side, height: side)
        let completion = ImageProcessingCompletionFlag()
        let baselineResidentBytes = try residentSize()
        var peakResidentBytes = baselineResidentBytes
        let startedAt = Date()

        let processingTask = Task.detached(priority: .userInitiated) {
            defer { completion.markCompleted() }
            return try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: png, isPNG: true)
            )
        }
        while !completion.isCompleted {
            peakResidentBytes = max(peakResidentBytes, try residentSize())
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let payload = try await processingTask.value
        peakResidentBytes = max(peakResidentBytes, try residentSize())

        XCTAssertEqual(payload.width, side)
        XCTAssertEqual(payload.height, side)
        XCTAssertNotNil(payload.thumbnailData)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertLessThan(
            peakResidentBytes - baselineResidentBytes,
            UInt64(ClipboardImageProcessor.maximumProcessingResidentGrowthBytes)
        )
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

    private func makeSolidPNGData(width: Int, height: Int) throws -> Data {
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
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func residentSize() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(
                domain: NSMachErrorDomain,
                code: Int(result)
            )
        }
        return info.resident_size
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

    private func assertSameColor(
        _ lhs: NSColor?,
        _ rhs: NSColor?,
        orientation: Int,
        x: Int,
        y: Int
    ) {
        let lhs = lhs?.usingColorSpace(.deviceRGB)
        let rhs = rhs?.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(lhs)
        XCTAssertNotNil(rhs)
        XCTAssertEqual(lhs?.redComponent ?? -1, rhs?.redComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.greenComponent ?? -1, rhs?.greenComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.blueComponent ?? -1, rhs?.blueComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.alphaComponent ?? -1, rhs?.alphaComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
    }
}

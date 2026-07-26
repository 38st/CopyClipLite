import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CopyClipLite

enum NearLimitImageFixture {
    /// Produces deterministic, high-entropy RGB pixels whose canonical PNG is
    /// close to the encoded-image ceiling without exceeding it.
    static func canonicalPNG() throws -> ClipboardImagePayload {
        let side = 1_800
        let bytesPerRow = side * 4
        var pixels = Data(count: bytesPerRow * side)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            var state: UInt32 = 0xC0FF_EE11
            for pixel in 0..<(side * side) {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                let offset = pixel * 4
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 0xFF
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw FixtureError.imageCreationFailed
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.encodingFailed
        }

        return try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: encoded as Data, isPNG: true)
        )
    }

    private enum FixtureError: Error {
        case imageCreationFailed
        case destinationCreationFailed
        case encodingFailed
    }
}

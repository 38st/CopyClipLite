import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClipboardImageCandidate: Sendable {
    let data: Data
    let isPNG: Bool
}

enum ClipboardImageProcessingError: LocalizedError, Sendable {
    case encodedDataTooLarge
    case invalidImage
    case dimensionsTooLarge
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .encodedDataTooLarge:
            return "An image clip was skipped because it exceeds 10 MB."
        case .invalidImage:
            return "An image clip was skipped because its data is invalid."
        case .dimensionsTooLarge:
            return "An image clip was skipped because its pixel dimensions are too large."
        case .conversionFailed:
            return "An image clip was skipped because it could not be converted safely."
        }
    }
}

actor ClipboardImageProcessingService {
    func process(_ candidate: ClipboardImageCandidate) throws -> ClipboardImagePayload {
        try ClipboardImageProcessor.process(candidate)
    }
}

enum ClipboardImageProcessor {
    static let maximumEncodedBytes = 10 * 1024 * 1024
    static let maximumInputBytes = 30 * 1024 * 1024
    static let maximumDimension = 16_384
    static let maximumPixelCount = 100_000_000

    static func process(_ candidate: ClipboardImageCandidate) throws -> ClipboardImagePayload {
        guard candidate.data.count <= maximumInputBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }
        guard let source = CGImageSourceCreateWithData(candidate.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw ClipboardImageProcessingError.invalidImage
        }

        guard width <= maximumDimension,
              height <= maximumDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumPixelCount else {
            throw ClipboardImageProcessingError.dimensionsTooLarge
        }

        let pngData: Data
        if candidate.isPNG {
            pngData = candidate.data
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let converted = encodePNG(image) else {
                throw ClipboardImageProcessingError.conversionFailed
            }
            pngData = converted
        }
        guard pngData.count <= maximumEncodedBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        let thumbnailData = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ).flatMap(encodePNG)

        return ClipboardImagePayload(
            data: pngData,
            thumbnailData: thumbnailData,
            width: width,
            height: height,
            byteCount: pngData.count,
            contentHash: contentHash(for: pngData)
        )
    }

    static func contentHash(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

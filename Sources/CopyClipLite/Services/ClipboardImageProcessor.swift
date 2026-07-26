import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClipboardImageCandidate: Sendable {
    let data: Data
    let isPNG: Bool
}

enum ClipboardImageProcessingError: LocalizedError, Sendable, Equatable {
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

protocol ClipboardImageProcessing: Sendable {
    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload
}

actor ClipboardImageProcessingService: ClipboardImageProcessing {
    func process(_ candidate: ClipboardImageCandidate) throws -> ClipboardImagePayload {
        try Task.checkCancellation()
        let payload = try ClipboardImageProcessor.process(candidate)
        try Task.checkCancellation()
        return payload
    }
}

enum ClipboardImageProcessor {
    static let maximumEncodedBytes = 10 * 1024 * 1024
    static let maximumInputBytes = 30 * 1024 * 1024
    static let maximumDimension = 16_384
    static let maximumPixelCount = 4_096 * 4_096
    static let maximumProcessingResidentGrowthBytes = 512 * 1024 * 1024

    static func process(_ candidate: ClipboardImageCandidate) throws -> ClipboardImagePayload {
        guard candidate.data.count <= maximumInputBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }
        guard let source = CGImageSourceCreateWithData(candidate.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw ClipboardImageProcessingError.invalidImage
        }
        if candidate.isPNG,
           sourceType as String != UTType.png.identifier {
            throw ClipboardImageProcessingError.invalidImage
        }

        guard width <= maximumDimension,
              height <= maximumDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumPixelCount else {
            throw ClipboardImageProcessingError.dimensionsTooLarge
        }

        let normalizedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let normalizedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            normalizedOptions as CFDictionary
        ),
        normalizedImage.width > 0,
        normalizedImage.height > 0,
        normalizedImage.width <= maximumDimension,
        normalizedImage.height <= maximumDimension,
        normalizedImage.width.multipliedReportingOverflow(by: normalizedImage.height).overflow == false,
        normalizedImage.width * normalizedImage.height <= maximumPixelCount,
        let pngData = encodePNG(normalizedImage) else {
            throw ClipboardImageProcessingError.conversionFailed
        }
        guard pngData.count <= maximumEncodedBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }

        guard let normalizedSource = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            throw ClipboardImageProcessingError.conversionFailed
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let thumbnailData = CGImageSourceCreateThumbnailAtIndex(
            normalizedSource,
            0,
            thumbnailOptions as CFDictionary
        ).flatMap(encodePNG) else {
            throw ClipboardImageProcessingError.conversionFailed
        }

        return ClipboardImagePayload(
            data: pngData,
            thumbnailData: thumbnailData,
            width: normalizedImage.width,
            height: normalizedImage.height,
            byteCount: pngData.count,
            contentHash: contentHash(for: pngData)
        )
    }

    static func contentHash(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) != nil
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

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageCandidateSource: Sendable {
    case data(Data, isPNG: Bool)
    case fileURL(URL)
}

struct ClipboardImageCandidate: Sendable {
    let sources: [ClipboardImageCandidateSource]

    init(data: Data, isPNG: Bool) {
        sources = [.data(data, isPNG: isPNG)]
    }

    init(sources: [ClipboardImageCandidateSource]) {
        self.sources = sources
    }

    // Compatibility accessors for lightweight test processors that only use
    // in-memory candidates. Production processing walks every source in order.
    var data: Data {
        for case let .data(data, _) in sources {
            return data
        }
        return Data()
    }

    var isPNG: Bool {
        for case let .data(_, isPNG) in sources {
            return isPNG
        }
        return false
    }
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
        var firstError: Error?
        for source in candidate.sources {
            try Task.checkCancellation()
            do {
                switch source {
                case let .data(data, isPNG):
                    return try process(data: data, isPNG: isPNG)
                case let .fileURL(url):
                    return try process(data: try readBoundedImageFile(at: url), isPNG: false)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        throw firstError ?? ClipboardImageProcessingError.invalidImage
    }

    private static func process(data: Data, isPNG: Bool) throws -> ClipboardImagePayload {
        guard data.count <= maximumInputBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
        if isPNG,
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

        guard let thumbnailImage = makeThumbnail(from: normalizedImage, maximumPixelSize: 96),
              let thumbnailData = encodePNG(thumbnailImage) else {
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

    private static func readBoundedImageFile(at url: URL) throws -> Data {
        guard url.isFileURL else {
            throw ClipboardImageProcessingError.invalidImage
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ClipboardImageProcessingError.invalidImage
        }
        defer { try? handle.close() }

        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw ClipboardImageProcessingError.invalidImage
        }
        guard status.st_size <= maximumInputBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        do {
            while data.count <= maximumInputBytes {
                let remaining = maximumInputBytes + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(remaining, 1024 * 1024)),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            throw ClipboardImageProcessingError.invalidImage
        }
        guard data.count <= maximumInputBytes else {
            throw ClipboardImageProcessingError.encodedDataTooLarge
        }
        return data
    }

    private static func makeThumbnail(
        from image: CGImage,
        maximumPixelSize: Int
    ) -> CGImage? {
        let largestDimension = max(image.width, image.height)
        guard largestDimension > maximumPixelSize else {
            return image
        }

        let scale = CGFloat(maximumPixelSize) / CGFloat(largestDimension)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

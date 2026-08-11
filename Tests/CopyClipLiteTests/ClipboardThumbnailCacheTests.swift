import Foundation
import XCTest
@testable import CopyClipLite

@MainActor
final class ClipboardThumbnailCacheTests: XCTestCase {
    func testCachedThumbnailIsInvalidatedWhenSameIDRefersToDifferentImage() {
        let id = UUID()
        let cache = ClipboardThumbnailCache()
        let first = item(id: id, hash: "first-hash", fileName: "first.png")
        let second = item(id: id, hash: "second-hash", fileName: "second.png")
        let firstThumbnail = Data([1, 2, 3])

        guard case .load = cache.lookup(for: first, now: .distantPast) else {
            return XCTFail("Expected the first thumbnail to load")
        }
        cache.finishLoading(id: id, data: firstThumbnail, now: .distantPast)
        guard case let .data(cached) = cache.lookup(for: first, now: .distantPast) else {
            return XCTFail("Expected the first thumbnail to be cached")
        }
        XCTAssertEqual(cached, firstThumbnail)

        guard case .load = cache.lookup(for: second, now: .distantPast) else {
            return XCTFail("A replacement image must not reuse the old thumbnail")
        }
    }

    private func item(id: UUID, hash: String, fileName: String) -> ClipboardItem {
        ClipboardItem(
            id: id,
            image: ClipboardImagePayload(
                fileName: fileName,
                thumbnailFileName: "\(fileName)-thumb.png",
                width: 10,
                height: 10,
                byteCount: 100,
                contentHash: hash
            )
        )
    }
}

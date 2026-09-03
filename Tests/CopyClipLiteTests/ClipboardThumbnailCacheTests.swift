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

        guard case let .load(load) = cache.lookup(for: first, now: .distantPast) else {
            return XCTFail("Expected the first thumbnail to load")
        }
        cache.finishLoading(id: id, load: load, data: firstThumbnail, now: .distantPast)
        guard case let .data(cached) = cache.lookup(for: first, now: .distantPast) else {
            return XCTFail("Expected the first thumbnail to be cached")
        }
        XCTAssertEqual(cached, firstThumbnail)

        guard case .load = cache.lookup(for: second, now: .distantPast) else {
            return XCTFail("A replacement image must not reuse the old thumbnail")
        }
    }

    func testCompletionFromReplacedCacheCannotCompleteLoadIssuedByNewCache() {
        let id = UUID()
        let oldCache = ClipboardThumbnailCache()
        let newCache = ClipboardThumbnailCache()
        let item = item(id: id, hash: "stable-hash", fileName: "stable.png")

        guard case let .load(oldLoad) = oldCache.lookup(for: item, now: .distantPast) else {
            return XCTFail("Expected the old cache to issue a load")
        }
        newCache.finishLoading(id: id, load: oldLoad, data: Data([1]), now: .distantPast)

        guard case let .load(newLoad) = newCache.lookup(for: item, now: .distantPast) else {
            return XCTFail("The replacement cache must issue its own load")
        }
        newCache.finishLoading(id: id, load: oldLoad, data: Data([2]), now: .distantPast)
        guard case .unavailable = newCache.lookup(for: item, now: .distantPast) else {
            return XCTFail("A stale completion must not finish the replacement cache's load")
        }

        let expectedData = Data([3])
        newCache.finishLoading(id: id, load: newLoad, data: expectedData, now: .distantPast)
        guard case let .data(cachedData) = newCache.lookup(for: item, now: .distantPast) else {
            return XCTFail("Expected the replacement cache's thumbnail to be cached")
        }
        XCTAssertEqual(cachedData, expectedData)
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

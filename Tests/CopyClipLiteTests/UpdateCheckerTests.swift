import Foundation
import XCTest
@testable import CopyClipLite

private struct StubUpdateFeedLoader: UpdateFeedLoading {
    let result: Result<CopyClipRelease, Error>

    func latestRelease(from url: URL, userAgent: String) async throws -> CopyClipRelease {
        try result.get()
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testEquivalentTwoAndThreeComponentVersionsCompareEqual() throws {
        XCTAssertEqual(try XCTUnwrap(CopyClipVersion("1.0")), try XCTUnwrap(CopyClipVersion("1.0.0")))
        XCTAssertEqual(try XCTUnwrap(CopyClipVersion("v2.4")), try XCTUnwrap(CopyClipVersion("2.4.0")))
    }

    func testSemanticVersionComparisonDoesNotUseRawNumericStringOrdering() throws {
        XCTAssertGreaterThan(
            try XCTUnwrap(CopyClipVersion("1.10.0")),
            try XCTUnwrap(CopyClipVersion("1.9.9"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(CopyClipVersion("1.0.9")),
            try XCTUnwrap(CopyClipVersion("1.1.0"))
        )
    }

    func testUpdateCheckerReportsAvailableReleaseFromInjectedFeed() async throws {
        let releaseURL = try XCTUnwrap(URL(string: "https://example.com/releases/1.2.0"))
        let checker = UpdateChecker(
            loader: StubUpdateFeedLoader(
                result: .success(CopyClipRelease(version: "1.2.0", url: releaseURL))
            ),
            feedURL: try XCTUnwrap(URL(string: "https://example.com/feed")),
            currentVersion: "1.1.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        XCTAssertEqual(checker.state, .updateAvailable(version: "1.2.0", url: releaseURL))
    }

    func testMissingPublicFeedFailsTruthfully() {
        let checker = UpdateChecker(
            loader: StubUpdateFeedLoader(result: .failure(UpdateFeedError.invalidResponse)),
            feedURL: nil,
            currentVersion: "1.0.0"
        )

        checker.check()

        guard case let .failed(message) = checker.state else {
            XCTFail("Expected unavailable state, got \(checker.state)")
            return
        }
        XCTAssertTrue(message.contains("No public update channel"))
    }

    private func waitUntilNotChecking(_ checker: UpdateChecker) async {
        for _ in 0..<100 where checker.state == .checking {
            await Task.yield()
        }
    }
}

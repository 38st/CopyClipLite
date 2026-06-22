import XCTest
@testable import CopyClipLite

final class DateRelativeDescriptionTests: XCTestCase {
    func testRelativeDescriptionsUseStaticShortUnits() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(now.addingTimeInterval(-5).copyClipRelativeDescription(relativeTo: now), "just now")
        XCTAssertEqual(now.addingTimeInterval(-42).copyClipRelativeDescription(relativeTo: now), "42s ago")
        XCTAssertEqual(now.addingTimeInterval(-5 * 60).copyClipRelativeDescription(relativeTo: now), "5m ago")
        XCTAssertEqual(now.addingTimeInterval(-3 * 60 * 60).copyClipRelativeDescription(relativeTo: now), "3h ago")
        XCTAssertEqual(now.addingTimeInterval(-4 * 24 * 60 * 60).copyClipRelativeDescription(relativeTo: now), "4d ago")
    }

    func testFutureDatesDoNotShowNegativeDurations() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(now.addingTimeInterval(30).copyClipRelativeDescription(relativeTo: now), "just now")
    }
}

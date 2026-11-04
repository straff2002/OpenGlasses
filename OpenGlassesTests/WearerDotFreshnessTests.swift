import XCTest
@testable import OpenGlasses

/// Plan GM P0 — every row of the wearer-dot staleness table.
final class WearerDotFreshnessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(age: TimeInterval) -> WearerDotFreshness {
        WearerDotFreshness.forCard(fixAt: now.addingTimeInterval(-age), now: now)
    }

    private func route(age: TimeInterval) -> WearerDotFreshness {
        WearerDotFreshness.forRoute(lastDeltaAt: now.addingTimeInterval(-age), now: now)
    }

    // Place / where-am-I / places: < 60 s fresh, 60 s – 5 min aged, > 5 min stale.
    func testCardRows() {
        XCTAssertEqual(card(age: 0), .fresh)
        XCTAssertEqual(card(age: 59), .fresh)
        XCTAssertEqual(card(age: 60), .aged(seconds: 60))
        XCTAssertEqual(card(age: 120), .aged(seconds: 120))
        XCTAssertEqual(card(age: 300), .aged(seconds: 300))
        XCTAssertEqual(card(age: 301), .stale)
        XCTAssertEqual(card(age: 3_600), .stale)
    }

    // Live route: < 10 s fresh, 10 – 30 s aged ("updating…"), > 30 s stale.
    func testRouteRows() {
        XCTAssertEqual(route(age: 0), .fresh)
        XCTAssertEqual(route(age: 9), .fresh)
        XCTAssertEqual(route(age: 10), .aged(seconds: 10))
        XCTAssertEqual(route(age: 30), .aged(seconds: 30))
        XCTAssertEqual(route(age: 31), .stale)
    }

    func testAFixFromTheFutureIsFresh() {
        XCTAssertEqual(card(age: -20), .fresh, "a phone clock ahead of the watch's is not staleness")
        XCTAssertEqual(route(age: -5), .fresh)
    }

    func testMinutesAgo() {
        XCTAssertEqual(WearerDotFreshness.minutesAgo(60), 1)
        XCTAssertEqual(WearerDotFreshness.minutesAgo(130), 2)
        XCTAssertEqual(WearerDotFreshness.minutesAgo(299), 4)
        XCTAssertEqual(WearerDotFreshness.minutesAgo(10), 1)
    }
}

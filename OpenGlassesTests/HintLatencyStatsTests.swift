import XCTest
@testable import OpenGlasses

/// Plan MO §5: a session's latency is reported as p50 and p95, never an average.
final class HintLatencyStatsTests: XCTestCase {

    func testNoSamplesNoPercentiles() {
        let stats = HintLatencyStats()
        XCTAssertNil(stats.p50)
        XCTAssertNil(stats.p95)
        XCTAssertEqual(LiveHintsService.latencyToken(stats), "none")
    }

    func testNearestRank() {
        XCTAssertEqual(HintLatencyStats.percentile(50, of: [4, 1, 3, 2]), 2)
        XCTAssertEqual(HintLatencyStats.percentile(50, of: [5]), 5)
        XCTAssertEqual(HintLatencyStats.percentile(95, of: [1, 2]), 2)
        XCTAssertEqual(HintLatencyStats.percentile(100, of: [3, 1, 2]), 3)
        XCTAssertEqual(HintLatencyStats.percentile(0, of: [3, 1, 2]), 1)
    }

    func testP95OfTwentyIsTheNineteenth() {
        var stats = HintLatencyStats()
        for value in (1...20).reversed() { stats.record(TimeInterval(value)) }
        XCTAssertEqual(stats.p95, 19)
        XCTAssertEqual(stats.p50, 10)
    }

    func testOneSlowCallShowsInP95NotP50() {
        var stats = HintLatencyStats()
        for _ in 0..<19 { stats.record(0.8) }
        stats.record(9)
        XCTAssertEqual(stats.p50, 0.8)
        XCTAssertEqual(stats.p95, 0.8, "one slow call in twenty sits above p95")
        stats.record(9)
        XCTAssertEqual(stats.p95, 9)
    }

    func testBadSamplesAreIgnoredAndTheSamplesAreBounded() {
        var stats = HintLatencyStats()
        stats.record(-1)
        stats.record(.nan)
        stats.record(.infinity)
        XCTAssertEqual(stats.count, 0)
        for _ in 0..<(HintLatencyStats.maxSamples + 5) { stats.record(1) }
        XCTAssertEqual(stats.count, HintLatencyStats.maxSamples)
    }

    func testTheBands() {
        XCTAssertEqual(HintLatencyStats.band(1.49), .good)
        XCTAssertEqual(HintLatencyStats.band(1.5), .usable)
        XCTAssertEqual(HintLatencyStats.band(2.99), .usable)
        XCTAssertEqual(HintLatencyStats.band(3), .slow)
        XCTAssertEqual(HintLatencyStats.band(5), .slow)
        XCTAssertEqual(HintLatencyStats.band(5.01), .broken)
    }

    func testTheLogTokenIsMillisecondsAndAPrivacyToken() {
        var stats = HintLatencyStats()
        stats.record(0.82)
        stats.record(2.4)
        let token = LiveHintsService.latencyToken(stats)
        XCTAssertEqual(token, "p50ms-820.p95ms-2400")
        XCTAssertEqual(PrivacyToken(token).description, token)
    }
}

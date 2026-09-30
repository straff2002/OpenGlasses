import XCTest
@testable import OpenGlasses

/// Plan GI P1 — the locked-phone cache holds derived numbers only, expires them after 24 hours,
/// lives out of backups, clears on request, and an answer from it says how old it is.
final class HealthSummaryCacheTests: XCTestCase {

    private typealias F = HealthFixture
    private var directory: URL!
    private var cache: HealthSummaryCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthSummaryCacheTests_\(UUID().uuidString)", isDirectory: true)
        cache = HealthSummaryCache(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func steps(_ count: Double, asOf: Date) -> StepComparison {
        StepComparison(today: count, usualByNow: nil, usableDays: 0, asOf: asOf)
    }

    func testARoundTripKeepsTheNumbers() throws {
        let snapshot = HealthSummarySnapshot(
            heartRate: HeartRateSummary(latest: HeartRateReading(beatsPerMinute: 72, date: F.at(15, 8)),
                                        resting: nil, asOf: F.at(15, 8)),
            sleep: nil, steps: steps(6200, asOf: F.at(15, 8)))
        try cache.store(snapshot, now: F.at(15, 8))
        XCTAssertEqual(cache.load(now: F.at(15, 9)), snapshot)
    }

    func testPartsOlderThanADayExpire() throws {
        try cache.store(HealthSummarySnapshot(steps: steps(6200, asOf: F.at(14, 8))), now: F.at(14, 8))
        try cache.store(HealthSummarySnapshot(heartRate: HeartRateSummary(latest: nil, resting: nil,
                                                                          asOf: F.at(15, 7))),
                        now: F.at(15, 7))
        let loaded = try XCTUnwrap(cache.load(now: F.at(15, 8, 30)))
        XCTAssertNil(loaded.steps, "a 24.5-hour-old step count is gone")
        XCTAssertNotNil(loaded.heartRate)
    }

    func testAFullyExpiredCacheIsRemoved() throws {
        try cache.store(HealthSummarySnapshot(steps: steps(6200, asOf: F.at(13, 8))), now: F.at(13, 8))
        XCTAssertNil(cache.load(now: F.at(15, 8)))
        XCTAssertFalse(cache.hasEntry)
    }

    func testANewerPartMergesOverTheOldAndKeepsTheRest() throws {
        let sleep = SleepNight(morning: F.at(15, 0), windowEnd: F.at(15, 14), asleep: F.hours(7),
                               inBed: nil, stages: nil, awakenings: 0, asOf: F.at(15, 7))
        try cache.store(HealthSummarySnapshot(sleep: sleep, steps: steps(100, asOf: F.at(15, 7))),
                        now: F.at(15, 7))
        try cache.store(HealthSummarySnapshot(steps: steps(900, asOf: F.at(15, 8))), now: F.at(15, 8))
        let loaded = try XCTUnwrap(cache.load(now: F.at(15, 8)))
        XCTAssertEqual(loaded.sleep, sleep)
        XCTAssertEqual(loaded.steps?.today, 900)
    }

    func testTheFileIsExcludedFromBackupAndClears() throws {
        try cache.store(HealthSummarySnapshot(steps: steps(6200, asOf: F.at(15, 8))), now: F.at(15, 8))
        let values = try cache.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        cache.clear()
        XCTAssertFalse(cache.hasEntry)
        XCTAssertNil(cache.load(now: F.at(15, 8)))
    }

    func testACorruptFileIsDiscarded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.fileURL)
        XCTAssertNil(cache.load(now: F.now))
        XCTAssertFalse(cache.hasEntry)
    }

    // MARK: - Age phrasing

    func testAFreshSummaryHasNoAgeLead() {
        XCTAssertNil(F.phraser.asOfLead(F.at(15, 8, 55), now: F.now))
    }

    func testAnOlderSummaryFromTodaySaysItsTime() throws {
        let lead = try XCTUnwrap(F.phraser.asOfLead(F.at(15, 8, 10), now: F.now))
        XCTAssertTrue(lead.hasPrefix("As of 8:10"), lead)
        XCTAssertFalse(lead.contains("yesterday"))
    }

    func testYesterdaysSummarySaysYesterday() throws {
        let lead = try XCTUnwrap(F.phraser.asOfLead(F.at(14, 21, 40), now: F.now))
        XCTAssertTrue(lead.hasPrefix("As of yesterday at 9:40"), lead)
    }

    func testACachedStepCountIsSpokenWithItsAge() {
        let text = F.phraser.steps(steps(6200, asOf: F.at(15, 8, 10)), now: F.now)
        XCTAssertTrue(text.hasPrefix("As of 8:10"), text)
        XCTAssertTrue(text.contains("you'd taken 6,200 steps today"), text)
    }

    func testASleepSummaryReadMidNightSaysWhenItWasRead() {
        let partial = SleepNight(morning: F.at(15, 0), windowEnd: F.at(15, 14), asleep: F.hours(4),
                                 inBed: nil, stages: nil, awakenings: 0, asOf: F.at(15, 3))
        let text = F.phraser.sleep(partial, now: F.now)
        XCTAssertTrue(text.hasPrefix("As of 3:00"), text)
        XCTAssertTrue(text.contains("you slept 4 hours last night"), text)
    }
}

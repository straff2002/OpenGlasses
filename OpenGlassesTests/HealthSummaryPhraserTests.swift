import XCTest
@testable import OpenGlasses

/// Plan GI P1 — one rounded sentence per metric, honest absences, and never a word of advice.
final class HealthSummaryPhraserTests: XCTestCase {

    private typealias F = HealthFixture
    private let phraser = HealthFixture.phraser
    private let now = HealthFixture.now

    private func night(asleep: TimeInterval?, inBed: TimeInterval? = nil,
                       stages: SleepNight.StageTotals? = nil, awakenings: Int = 0,
                       morning: Date? = nil, asOf: Date? = nil) -> SleepNight {
        let morning = morning ?? F.calendar.startOfDay(for: now)
        return SleepNight(morning: morning,
                          windowEnd: F.calendar.date(bySettingHour: 14, minute: 0, second: 0, of: morning)!,
                          asleep: asleep, inBed: inBed, stages: stages, awakenings: awakenings,
                          asOf: asOf ?? now)
    }

    // MARK: - Heart rate

    func testHeartRateRoundsToTheBeatAndNamesTheDay() {
        let summary = HeartRateSummary(
            latest: HeartRateReading(beatsPerMinute: 71.6, date: F.at(15, 8, 57)),
            resting: HeartRateReading(beatsPerMinute: 58.2, date: F.at(15, 6)), asOf: now)
        XCTAssertEqual(phraser.heartRate(summary, now: now),
                       "Your heart rate was 72 beats per minute a few minutes ago; resting 58 today.")
    }

    func testHeartRateAgeAndAnEarlierRestingDay() {
        let summary = HeartRateSummary(
            latest: HeartRateReading(beatsPerMinute: 80, date: F.at(15, 8, 22)),
            resting: HeartRateReading(beatsPerMinute: 60, date: F.at(13, 6)), asOf: now)
        let text = phraser.heartRate(summary, now: now)
        XCTAssertTrue(text.contains("about 40 minutes ago"), text)
        XCTAssertTrue(text.contains("resting 60 on Tuesday"), text)   // 13 October 2026
    }

    func testNoHeartRateIsAnHonestAbsence() {
        XCTAssertEqual(phraser.heartRate(nil, now: now), HealthSummaryPhraser.noHeartRate)
        XCTAssertEqual(phraser.heartRate(HeartRateSummary(latest: nil, resting: nil, asOf: now), now: now),
                       HealthSummaryPhraser.noHeartRate)
        XCTAssertTrue(HealthSummaryPhraser.noHeartRate.contains("watch"))
    }

    // MARK: - Sleep

    func testSleepRoundsToTenMinutesAndNamesStagesAndWaking() {
        let text = phraser.sleep(night(asleep: F.hours(7) + 13 * 60,
                                       stages: .init(core: F.hours(4), deep: 78 * 60, rem: 102 * 60),
                                       awakenings: 2), now: now)
        XCTAssertEqual(text, "You slept 7 hours, 10 minutes last night, including about "
                       + "1 hour, 20 minutes deep and 1 hour, 40 minutes REM, and woke twice.")
    }

    func testSleepWithoutStagesSaysOnlyTheTotal() {
        XCTAssertEqual(phraser.sleep(night(asleep: F.hours(6.5)), now: now),
                       "You slept 6 hours, 30 minutes last night.")
    }

    func testInBedOnlyDoesNotClaimSleep() {
        let text = phraser.sleep(night(asleep: nil, inBed: F.hours(8)), now: now)
        XCTAssertEqual(text, "Apple Health recorded 8 hours in bed last night, but not time asleep.")
    }

    func testAnOlderNightIsNotLastNight() {
        let olderMorning = F.calendar.date(byAdding: .day, value: -1, to: F.calendar.startOfDay(for: now))!
        XCTAssertTrue(phraser.sleep(night(asleep: F.hours(7), morning: olderMorning), now: now)
            .contains("the night before last"))
        let muchOlder = F.calendar.date(byAdding: .day, value: -3, to: F.calendar.startOfDay(for: now))!
        XCTAssertEqual(phraser.sleep(night(asleep: F.hours(7), morning: muchOlder), now: now),
                       HealthSummaryPhraser.noSleep)
        XCTAssertEqual(phraser.sleep(nil, now: now), HealthSummaryPhraser.noSleep)
    }

    // MARK: - Steps

    func testStepsRoundToTheHundredWithTheComparison() {
        let steps = StepComparison(today: 6230, usualByNow: 4710, usableDays: 10, asOf: now)
        XCTAssertEqual(phraser.steps(steps, now: now),
                       "You've taken 6,200 steps so far today, about 1,500 more than usual by now.")
    }

    func testStepsBehindAndAboutUsual() {
        let behind = StepComparison(today: 2000, usualByNow: 4000, usableDays: 10, asOf: now)
        XCTAssertTrue(phraser.steps(behind, now: now).contains("about 2,000 fewer than usual by now"))
        let level = StepComparison(today: 4100, usualByNow: 4000, usableDays: 10, asOf: now)
        XCTAssertTrue(phraser.steps(level, now: now).contains("about your usual by now"))
    }

    func testStepsWithoutABaselineAndVeryFewSteps() {
        XCTAssertEqual(phraser.steps(StepComparison(today: 6200, usualByNow: nil, usableDays: 2, asOf: now), now: now),
                       "You've taken 6,200 steps so far today.")
        XCTAssertEqual(phraser.steps(StepComparison(today: 40, usualByNow: nil, usableDays: 0, asOf: now), now: now),
                       "You've taken fewer than 100 steps so far today.")
    }

    func testYesterdaysStepsAreNotToday() {
        let stale = StepComparison(today: 12000, usualByNow: nil, usableDays: 0, asOf: F.at(14, 21))
        XCTAssertEqual(phraser.steps(stale, now: now), HealthSummaryPhraser.noSteps)
    }

    func testNumbersFollowTheLocale() {
        let german = HealthSummaryPhraser(locale: Locale(identifier: "de_DE"), calendar: F.calendar)
        XCTAssertEqual(german.number(6200), "6.200")
        XCTAssertEqual(phraser.number(6200), "6,200")
    }

    // MARK: - Overview

    func testOverviewIsAtMostTwoSentences() {
        let text = phraser.overview(
            heartRate: HeartRateSummary(latest: nil,
                                        resting: HeartRateReading(beatsPerMinute: 58, date: F.at(15, 6)),
                                        asOf: now),
            sleep: night(asleep: F.hours(7), stages: .init(core: 1, deep: F.hours(1), rem: F.hours(1)),
                         awakenings: 3),
            steps: StepComparison(today: 3000, usualByNow: 2000, usableDays: 9, asOf: now),
            now: now)
        XCTAssertEqual(text, "You slept 7 hours last night. You've taken 3,000 steps so far today, "
                       + "and your resting heart rate was 58 today.")
        XCTAssertEqual(text.filter { $0 == "." }.count, 2)
    }

    func testOverviewWithNothingSaysSo() {
        XCTAssertEqual(phraser.overview(heartRate: nil, sleep: nil, steps: nil, now: now),
                       HealthSummaryPhraser.noData)
    }

    // MARK: - Never advice

    func testNoSentenceInterpretsOrAdvises() {
        let banned = ["normal", "healthy", "unhealthy", "should", "doctor", "concern", "worry",
                      "good", "bad", "great", "poor", "risk", "recommend", "too high", "too low"]
        let texts = [
            phraser.heartRate(HeartRateSummary(latest: HeartRateReading(beatsPerMinute: 140, date: now),
                                               resting: HeartRateReading(beatsPerMinute: 95, date: now),
                                               asOf: now), now: now),
            phraser.sleep(night(asleep: F.hours(3), awakenings: 9), now: now),
            phraser.steps(StepComparison(today: 200, usualByNow: 9000, usableDays: 14, asOf: now), now: now),
            phraser.overview(heartRate: nil, sleep: night(asleep: F.hours(3)), steps: nil, now: now),
            HealthSummaryPhraser.noHeartRate, HealthSummaryPhraser.noSleep, HealthSummaryPhraser.noSteps,
            HealthSummaryPhraser.noData, HealthSummaryPhraser.lockedNoCache,
            HealthSummaryPhraser.needsPermission, HealthSummaryPhraser.healthUnavailable,
        ]
        for text in texts {
            for word in banned {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(word)\" in: \(text)")
            }
        }
    }
}

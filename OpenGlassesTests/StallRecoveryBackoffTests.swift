import XCTest
@testable import OpenGlasses

/// A device trace from 2026-09-25 showed fourteen stall recoveries in a row, about 9 s apart,
/// and not one of the rebuilt streams delivered a frame. Rebuilding immediately every time only
/// repeated the failure. These tests pin the pacing that replaces it: rebuild at once after
/// healthy streaming, back off after each attempt that delivered nothing, drop the tier after
/// two of those, and stop after six.
final class StallRecoveryBackoffTests: XCTestCase {

    /// The first stall after frames were flowing is handled exactly as before: rebuild now, at
    /// the tier the wearer chose.
    func testTheFirstStallRebuildsImmediatelyAtTheRequestedTier() {
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: 0),
                       .rebuild(delay: 0, stepDownTier: false))
    }

    /// Each rebuild that got nothing through waits longer before the next one. That is what stops
    /// the every-9-seconds loop.
    func testEachFramelessRebuildWaitsLongerThanTheLast() {
        let delays = (0..<StallRecoveryBackoff.maxFramelessRecoveries)
            .map { StallRecoveryBackoff.delay(framelessRecoveries: $0) }
        XCTAssertEqual(delays, [0, 3, 6, 12, 24, 30])
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThan(earlier, later)
        }
    }

    /// The wait is capped. A glasses link that is re-associating is polled, not abandoned for
    /// minutes at a time. Large counts must not overflow either.
    func testTheDelayIsCapped() {
        XCTAssertEqual(StallRecoveryBackoff.delay(framelessRecoveries: 5), StallRecoveryBackoff.maxDelay)
        XCTAssertEqual(StallRecoveryBackoff.delay(framelessRecoveries: 1_000), StallRecoveryBackoff.maxDelay)
    }

    /// Two frameless rebuilds at a tier are enough to say that tier is not working on this link.
    /// The third attempt asks for less.
    func testTheTierStepsDownAfterRepeatedFramelessRebuilds() {
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: 1),
                       .rebuild(delay: 3, stepDownTier: false))
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: 2),
                       .rebuild(delay: 6, stepDownTier: true))
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: 5),
                       .rebuild(delay: 30, stepDownTier: true))
    }

    /// Past the budget more rebuilds will not help, and the wearer is told instead.
    func testRecoveryGivesUpAfterTheBudget() {
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: StallRecoveryBackoff.maxFramelessRecoveries),
                       .giveUp)
        XCTAssertEqual(StallRecoveryBackoff.decision(framelessRecoveries: 50), .giveUp)
    }

    /// High steps down to medium. Medium does not step down to low: below medium the stream can
    /// move onto the Bluetooth radio and starve the glasses mic, and the live voice modes floor
    /// low back up to medium anyway.
    func testSteppingDownGoesHighToMediumAndNoLower() {
        XCTAssertEqual(StallRecoveryBackoff.steppedDown(resolution: "high"), "medium")
        XCTAssertEqual(StallRecoveryBackoff.steppedDown(resolution: "medium"), "medium")
        XCTAssertEqual(StallRecoveryBackoff.steppedDown(resolution: "low"), "low")
    }

    /// An unrecognised setting streams as high, so it steps down like high.
    func testAnUnknownResolutionStepsDownLikeHigh() {
        XCTAssertEqual(StallRecoveryBackoff.steppedDown(resolution: "ultra"), "medium")
    }

    /// The backoff adds 75 s of waiting in total before recovery gives up, so a dead camera ends
    /// with a notice rather than an endless "Connecting…".
    func testTheTotalWaitIsBounded() {
        let total = (0..<StallRecoveryBackoff.maxFramelessRecoveries)
            .map { StallRecoveryBackoff.delay(framelessRecoveries: $0) }
            .reduce(0, +)
        XCTAssertEqual(total, 75)
    }
}

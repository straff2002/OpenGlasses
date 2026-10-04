import XCTest
@testable import OpenGlasses

/// What may be removed for a recorded job and when. Above all: nothing before the office has
/// acknowledged it.
final class RetentionDecisionTests: XCTestCase {
    private typealias R = RetentionDecision

    private let stopped = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func recording(acknowledgedAfter days: Double? = nil, trimmed: Bool = false) -> R.Recording {
        R.Recording(waitingSince: stopped, acknowledgedAt: days.map { stopped.addingTimeInterval($0 * day) },
                    mediaTrimmed: trimmed)
    }

    private func after(_ days: Double) -> Date { stopped.addingTimeInterval(days * day) }

    // MARK: - The defaults

    func testTheDefaultsAreTheOnesDecided() {
        let limits = R.Limits.standard
        XCTAssertEqual(limits.sessionBytes, 2_000_000_000)
        XCTAssertEqual(limits.unsyncedBytes, 8_000_000_000)
        XCTAssertEqual(limits.trimAfterAcknowledgement, 7 * day)
        XCTAssertEqual(limits.expiryAfter, 30 * day)
    }

    // MARK: - Never before acknowledgement

    func testAnUnacknowledgedRecordingIsNeverTrimmedHoweverLongItWaits() {
        for days in [0, 1, 7, 8, 29.99, 30, 31, 365, 3_650] {
            let action = R.decide(recording(), now: after(days))
            XCTAssertNotEqual(action, .trimMedia, "\(days) days")
            XCTAssertNotEqual(action, .keepRecord, "\(days) days")
        }
    }

    func testEveryPhaseShortOfAcknowledgedKeepsEverythingOrAsks() {
        let bundleID = "0123456789abcdef0123456789abcdef"
        let manifest = String(repeating: "a", count: 64)
        var state = BundleSyncState(bundleID: bundleID)
        var unacknowledged = [state]
        for event: BundleSyncState.Event in [.recordingStopped, .sealed(manifestSHA256: manifest, totalBytes: 10),
                                             .notEligible(.noNetwork), .transferStarted, .allChunksServed] {
            XCTAssertTrue(state.apply(event))
            unacknowledged.append(state)
        }
        var refused = state
        refused.apply(.receipt(.init(bundleID: bundleID, manifestSHA256: manifest, status: .refused(.digest))))
        var expired = state
        expired.apply(.expiryReached)
        unacknowledged += [refused, expired]

        for state in unacknowledged {
            // Even when a date for an acknowledgement is handed in, a state that is not acknowledged
            // is not treated as if it were.
            for days in [0.0, 8, 40] {
                let action = R.decide(state, waitingSince: stopped, acknowledgedAt: stopped, now: after(days))
                XCTAssertTrue(action == .keepEverything || action == .askTechnician, "\(state.phase) after \(days) days: \(action)")
            }
        }

        // Delivered is not acknowledged; the receipt is what starts the clock.
        XCTAssertEqual(state.phase, .delivered)
        XCTAssertEqual(R.decide(state, waitingSince: stopped, acknowledgedAt: nil, now: after(20)), .keepEverything)
        state.apply(.receipt(.init(bundleID: bundleID, manifestSHA256: manifest, status: .received)))
        XCTAssertEqual(R.decide(state, waitingSince: stopped, acknowledgedAt: after(1), now: after(7.9)), .keepEverything)
        XCTAssertEqual(R.decide(state, waitingSince: stopped, acknowledgedAt: after(1), now: after(8)), .trimMedia)
        state.apply(.mediaTrimmed)
        XCTAssertEqual(R.decide(state, waitingSince: stopped, acknowledgedAt: after(1), now: after(400)), .keepRecord)
    }

    // MARK: - After acknowledgement

    func testMediaIsTrimmedSevenDaysAfterAcknowledgementAndNotBefore() {
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2), now: after(2)), .keepEverything)
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2), now: after(8.999)), .keepEverything)
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2), now: after(9)), .trimMedia)
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2), now: after(60)), .trimMedia)
    }

    func testTheSevenDaysRunFromTheAcknowledgementNotFromTheRecording() {
        // Acknowledged on day 29: on day 31 the recording is neither expired nor ready to trim.
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 29), now: after(31)), .keepEverything)
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 29), now: after(36)), .trimMedia)
    }

    func testOnceTrimmedWhatIsLeftStays() {
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2, trimmed: true), now: after(9)), .keepRecord)
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2, trimmed: true), now: after(4_000)), .keepRecord)
    }

    func testAClockThatWentBackwardsTrimsNothing() {
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 2), now: after(-5)), .keepEverything)
        XCTAssertEqual(R.decide(recording(), now: after(-5)), .keepEverything)
    }

    // MARK: - Expiry

    func testAfterThirtyDaysUnacknowledgedTheTechnicianIsAskedAndNothingIsRemoved() {
        XCTAssertEqual(R.decide(recording(), now: after(29.999)), .keepEverything)
        XCTAssertEqual(R.decide(recording(), now: after(30)), .askTechnician)
        XCTAssertEqual(R.decide(recording(), now: after(300)), .askTechnician)
    }

    func testChoosingToKeepWaitingStartsTheThirtyDaysAgain() {
        var kept = recording()
        kept.waitingSince = after(31)
        XCTAssertEqual(R.decide(kept, now: after(32)), .keepEverything)
        XCTAssertEqual(R.decide(kept, now: after(61)), .askTechnician)
    }

    func testTheLimitsCanBeChanged() {
        var limits = R.Limits()
        limits.trimAfterAcknowledgement = day
        limits.expiryAfter = 2 * day
        XCTAssertEqual(R.decide(recording(acknowledgedAfter: 0), now: after(1), limits: limits), .trimMedia)
        XCTAssertEqual(R.decide(recording(), now: after(2), limits: limits), .askTechnician)
    }

    // MARK: - Size limits

    func testANewRecordingIsRefusedWhenThePhoneHoldsEightGigabytesUnsent() {
        XCTAssertEqual(R.mayStartRecording(unsyncedBytes: 0), .allowed)
        XCTAssertEqual(R.mayStartRecording(unsyncedBytes: 7_999_999_999), .allowed)
        guard case let .refused(why) = R.mayStartRecording(unsyncedBytes: 8_000_000_000) else {
            return XCTFail("the limit itself is full")
        }
        // The reason, and what to do about it.
        XCTAssertTrue(why.contains("unsent recordings"), why)
        XCTAssertTrue(why.contains("office Wi-Fi") && why.contains("plug the phone in"), why)
        XCTAssertNotEqual(R.mayStartRecording(unsyncedBytes: 20_000_000_000), .allowed)
    }

    func testARecordingStopsAtTwoGigabytes() {
        XCTAssertFalse(R.mustStopRecording(sessionBytes: 1_999_999_999))
        XCTAssertTrue(R.mustStopRecording(sessionBytes: 2_000_000_000))
        XCTAssertTrue(R.stoppedAtLimitNote.contains("saved"), "stopping at the limit loses nothing, and says so")
    }

    // MARK: - Deleting the job

    func testDeletingAJobWithAnUnacknowledgedRecordingAsksFirst() {
        XCTAssertTrue(R.deletionNeedsConfirmation(recording()))
        XCTAssertFalse(R.deletionNeedsConfirmation(recording(acknowledgedAfter: 1)))
        XCTAssertFalse(R.deletionNeedsConfirmation(recording(acknowledgedAfter: 1, trimmed: true)))
        XCTAssertTrue(R.unacknowledgedDeletionWarning.contains("hasn't received"))
    }
}

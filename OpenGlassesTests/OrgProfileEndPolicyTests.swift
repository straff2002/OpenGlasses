import XCTest
@testable import OpenGlasses

/// Plan CT — the organisation's signed term has ended: a notice only. When it shows, what it says,
/// and that a lease lapse on its own, a clock wound back or an open job never change the answer the
/// wrong way.
final class OrgProfileEndPolicyTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private let expiry = Date(timeIntervalSince1970: 1_790_000_000)

    private func input(now: Date, expiry: Date? = nil, highWater: Date? = nil, jobOpen: Bool = false,
                       reports: Int = 0, sessions: Int = 0,
                       source: ProfileSource = .licence) -> OrgProfileEndPolicy.Input {
        OrgProfileEndPolicy.Input(organizationName: "Acme Elevator", policyExpiry: expiry, now: now,
                                  clockHighWater: highWater, jobOpen: jobOpen, owedReports: reports,
                                  owedSessions: sessions, source: source)
    }

    private var endedOn: String { expiry.formatted(date: .abbreviated, time: .omitted) }

    // MARK: - When

    func testNoTermNeverEnds() {
        for source in ProfileSource.allCases {
            XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(3_650 * day),
                                                            source: source)),
                           .inForce, "\(source): a profile without policyExpiry is unchanged")
        }
    }

    func testInForceUntilTheTermEndsAndEndedFromThatMoment() {
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(-1), expiry: expiry)),
                       .inForce)
        XCTAssertNotNil(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry)).notice,
                        "ends at the same moment the lease counts it lapsed")
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(40 * day),
                                                        expiry: expiry)).notice?.endedOn,
                       expiry)
    }

    /// Office-commissioned phones cannot renew, so their lease always lapses `leaseDays` after
    /// enrolment. The rule does not read the lease at all: only the organisation's own term.
    func testAnOfficePhoneWhoseTermIsAheadIsInForceHoweverLongSinceEnrolment() {
        let later = expiry.addingTimeInterval(400 * day)
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(-1),
                                                        expiry: later, source: .office)),
                       .inForce)
    }

    // MARK: - The clock

    func testAClockWoundBackDoesNotHideTheNotice() {
        let woundBack = expiry.addingTimeInterval(-30 * day)
        let highWater = expiry.addingTimeInterval(2 * day)
        XCTAssertNotNil(OrgProfileEndPolicy.decide(input(now: woundBack, expiry: expiry,
                                                         highWater: highWater)).notice)
    }

    func testAHighWaterBeforeTheTermIsNotAnEnd() {
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(-2 * day), expiry: expiry,
                                                        highWater: expiry.addingTimeInterval(-day))),
                       .inForce)
    }

    func testAClockMovedForwardShowsItEarlyWhichIsAcceptable() {
        // A notice is harmless early; nothing is removed.
        XCTAssertNotNil(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(day), expiry: expiry,
                                                         highWater: expiry.addingTimeInterval(-10 * day))).notice)
    }

    // MARK: - A job open

    func testQuietWhileAJobIsOpenAndShownOnceItCloses() {
        let after = expiry.addingTimeInterval(day)
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: after, expiry: expiry, jobOpen: true)),
                       .endedDuringJob(endedOn: expiry))
        XCTAssertNil(OrgProfileEndPolicy.decide(input(now: after, expiry: expiry, jobOpen: true)).notice)
        XCTAssertNotNil(OrgProfileEndPolicy.decide(input(now: after, expiry: expiry, jobOpen: false)).notice)
    }

    func testAJobOpenBeforeTheTermEndsIsSimplyInForce() {
        XCTAssertEqual(OrgProfileEndPolicy.decide(input(now: expiry.addingTimeInterval(-day), expiry: expiry,
                                                        jobOpen: true)),
                       .inForce)
    }

    // MARK: - What it says

    func testRemovableWithNothingOwed() throws {
        let notice = try XCTUnwrap(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry)).notice)
        XCTAssertFalse(notice.recordsOwed)
        XCTAssertTrue(notice.removableHere)
        XCTAssertEqual(notice.settingsText,
                       "Acme Elevator's profile ended on \(endedOn). To remove it, go to Settings › Organisation › Acme Elevator and choose Remove Profile under Leave Acme Elevator.")
        XCTAssertEqual(notice.pageText,
                       "Acme Elevator's profile ended on \(endedOn). To remove it, choose Remove Profile under Leave Acme Elevator at the bottom of this page.")
        XCTAssertEqual(notice.settingsHint, "Opens Acme Elevator's page.")
        XCTAssertEqual(notice.pageHint, "Shows Leave Acme Elevator at the bottom of this page.")
    }

    func testRecordsOwedSaysToSendThemFirst() throws {
        let owed = " Send Acme Elevator its records first: Remove Profile offers that before anything is removed."
        for (reports, sessions) in [(2, 0), (0, 3), (1, 1)] {
            let notice = try XCTUnwrap(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry,
                                                                        reports: reports,
                                                                        sessions: sessions)).notice)
            XCTAssertTrue(notice.recordsOwed, "reports \(reports), sessions \(sessions)")
            XCTAssertTrue(notice.settingsText.hasSuffix(owed))
            XCTAssertTrue(notice.pageText.hasSuffix(owed))
        }
    }

    func testEveryLocallyRemovableSourceGetsTheLeaveInstruction() throws {
        for source in ProfileSource.allCases where source.isLocallyRemovable {
            let notice = try XCTUnwrap(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry,
                                                                        source: source)).notice)
            XCTAssertTrue(notice.removableHere, "\(source)")
            XCTAssertTrue(notice.settingsText.contains("Remove Profile under Leave Acme Elevator"), "\(source)")
        }
    }

    func testAnMDMProfileSaysDeviceManagementRemovesItAndNoLeaveInstruction() throws {
        let notice = try XCTUnwrap(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry, reports: 2,
                                                                    source: .managedConfig)).notice)
        XCTAssertFalse(notice.removableHere)
        let expected = "Acme Elevator's profile ended on \(endedOn). Your organisation's device management removes it from this phone."
        XCTAssertEqual(notice.settingsText, expected)
        XCTAssertEqual(notice.pageText, expected)
        XCTAssertFalse(notice.settingsText.contains("Leave"))
        XCTAssertFalse(notice.settingsText.contains("Remove Profile"))
    }

    func testTheDateIsTheOneTheAppAlreadyShows() throws {
        // `ManagedByOrganisationSection.subtitle` and the lease notices format dates this way.
        let notice = try XCTUnwrap(OrgProfileEndPolicy.decide(input(now: expiry, expiry: expiry)).notice)
        XCTAssertTrue(notice.settingsText.contains("ended on \(expiry.formatted(date: .abbreviated, time: .omitted))."))
    }
}

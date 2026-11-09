import XCTest
@testable import OpenGlasses

final class AssistingPresenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func held(_ id: String, org: String = "Northside Heating", taken: Bool = false, running: Bool = false,
                      at offset: TimeInterval = 0, dismissed: Bool = false) -> AssistingPresence.HeldFact {
        .init(id: id, organisation: org, taken: taken, running: running, receivedAt: t0.addingTimeInterval(offset),
              dismissed: dismissed)
    }

    private func invite(_ id: String, org: String = "Northside Heating", at offset: TimeInterval = 0,
                        dismissed: Bool = false) -> AssistingPresence.InviteFact {
        .init(id: id, organisation: org, receivedAt: t0.addingTimeInterval(offset), dismissed: dismissed)
    }

    // MARK: - Present

    func testNothingIsAbsent() {
        let presence = AssistingPresence.make(hasCard: false, held: [], hasLedger: false, invites: [])
        XCTAssertEqual(presence, .absent)
    }

    func testEachFactOnItsOwnMakesItPresent() {
        XCTAssertTrue(AssistingPresence.make(hasCard: true, held: [], hasLedger: false, invites: []).isPresent)
        XCTAssertTrue(AssistingPresence.make(hasCard: false, held: [held("h1")], hasLedger: false, invites: []).isPresent)
        XCTAssertTrue(AssistingPresence.make(hasCard: false, held: [], hasLedger: true, invites: []).isPresent,
                      "Last month's time can still be exported after the card is deleted")
        XCTAssertTrue(AssistingPresence.make(hasCard: false, held: [], hasLedger: false, invites: [invite("i1")]).isPresent)
    }

    // MARK: - The Home card

    func testACardOrALedgerAlonePutsNothingOnHome() {
        XCTAssertNil(AssistingPresence.make(hasCard: true, held: [], hasLedger: true, invites: []).homeCard)
    }

    func testAFinishedJobPutsNothingOnHome() {
        let done = held("h1", taken: true, running: false)
        XCTAssertNil(AssistingPresence.make(hasCard: true, held: [done], hasLedger: false, invites: []).homeCard)
    }

    func testOneNewJobNamesItsOrganisation() {
        let card = AssistingPresence.make(hasCard: true, held: [held("h1")], hasLedger: false, invites: []).homeCard
        XCTAssertEqual(card, .newJobs(ids: ["h1"], organisation: "Northside Heating"))
    }

    func testJobsFromTwoOrganisationsNameNone() {
        let card = AssistingPresence.make(hasCard: true, held: [held("h1", at: 0), held("h2", org: "Bay Air", at: 10)],
                                          hasLedger: false, invites: []).homeCard
        XCTAssertEqual(card, .newJobs(ids: ["h2", "h1"], organisation: ""))
    }

    func testARunningClockComesBeforeNewJobsAndInvites() {
        let card = AssistingPresence.make(hasCard: true,
                                          held: [held("h1", taken: true, running: true), held("h2", at: 10)],
                                          hasLedger: false, invites: [invite("i1")]).homeCard
        XCTAssertEqual(card, .clock(handoverId: "h1", organisation: "Northside Heating", count: 1))
    }

    func testNewJobsComeBeforeAnInvite() {
        let card = AssistingPresence.make(hasCard: false, held: [held("h1")], hasLedger: false,
                                          invites: [invite("i1", at: 100)]).homeCard
        XCTAssertEqual(card, .newJobs(ids: ["h1"], organisation: "Northside Heating"))
    }

    func testTheNewestInviteIsTheOneShown() {
        let card = AssistingPresence.make(hasCard: false, held: [], hasLedger: false,
                                          invites: [invite("i1", at: 0), invite("i2", org: "Bay Air", at: 10)]).homeCard
        XCTAssertEqual(card, .invite(inviteId: "i2", organisation: "Bay Air"))
    }

    func testTwoRunningClocksCountAndShowTheNewest() {
        let card = AssistingPresence.make(hasCard: true,
                                          held: [held("h1", taken: true, running: true, at: 0),
                                                 held("h2", org: "Bay Air", taken: true, running: true, at: 10)],
                                          hasLedger: false, invites: []).homeCard
        XCTAssertEqual(card, .clock(handoverId: "h2", organisation: "Bay Air", count: 2))
    }

    // MARK: - Dismissal

    func testADismissedJobFallsThroughToAnInvite() {
        let card = AssistingPresence.make(hasCard: false, held: [held("h1", dismissed: true)], hasLedger: false,
                                          invites: [invite("i1")]).homeCard
        XCTAssertEqual(card, .invite(inviteId: "i1", organisation: "Northside Heating"))
    }

    func testANewJobAfterADismissedOneShowsOnlyTheNewOne() {
        let card = AssistingPresence.make(hasCard: true,
                                          held: [held("h1", dismissed: true), held("h2", at: 10)],
                                          hasLedger: false, invites: []).homeCard
        XCTAssertEqual(card, .newJobs(ids: ["h2"], organisation: "Northside Heating"))
    }

    func testARunningClockCantBeDismissed() {
        let card = AssistingPresence.make(hasCard: true,
                                          held: [held("h1", taken: true, running: true, dismissed: true)],
                                          hasLedger: false, invites: []).homeCard
        XCTAssertEqual(card?.dismissalIds, [])
        XCTAssertNotNil(card)
    }

    func testDismissedEverythingLeavesPresentButNoCard() {
        let presence = AssistingPresence.make(hasCard: false, held: [held("h1", dismissed: true)], hasLedger: false,
                                              invites: [invite("i1", dismissed: true)])
        XCTAssertTrue(presence.isPresent)
        XCTAssertNil(presence.homeCard)
    }

    func testDismissalIdsAreEveryWaitingJob() {
        let card = AssistingPresence.HomeCard.newJobs(ids: ["h2", "h1"], organisation: "")
        XCTAssertEqual(card.dismissalIds, ["h2", "h1"])
        XCTAssertEqual(AssistingPresence.HomeCard.invite(inviteId: "i1", organisation: "").dismissalIds, ["i1"])
    }

    // MARK: - Things to Try

    func testTheCardLinkShowsOnlyWithoutACard() {
        XCTAssertTrue(ExpertCardLink.isVisible(hasCard: false))
        XCTAssertFalse(ExpertCardLink.isVisible(hasCard: true))
    }
}

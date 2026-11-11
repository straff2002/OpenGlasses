import XCTest
@testable import OpenGlasses

/// Plan KT P0 — the Field Assist kinds, a table per rule.
final class PreparedCardJobRulesTests: XCTestCase {
    private typealias F = CardFixtures
    private let rules = F.rules
    private let settings = F.settings

    // MARK: - On my way: leave-by for the next job within 30 min

    func testOnMyWayAppearsThirtyMinutesBeforeLeaveByUntilTheJobsTime() {
        // Leave-by 09:30, 25 min on the road, the job at 10:00.
        let table: [(Date, Bool)] = [
            (F.at(8, 59, 59), false),
            (F.at(9), true),
            (F.at(9, 33), true),       // arriving 09:58: still on time
            (F.at(9, 33, 1), false),   // now running late instead
        ]
        for (now, appears) in table {
            XCTAssertEqual(rules.jobOnMyWay(F.jobInputs(), now: now, settings: settings) != nil, appears, "at \(now)")
        }
    }

    func testOnMyWayTextsTheCustomerFromTheWearerAndCompany() throws {
        let card = try XCTUnwrap(rules.jobOnMyWay(F.jobInputs(), now: F.at(9, 10), settings: settings)?.card)
        XCTAssertEqual(card.id.rawValue, "jobOnMyWay:1005:2026-11-12")
        XCTAssertEqual(card.primary, .directions(destination: "14 Example Street", mode: .driving))
        XCTAssertEqual(card.secondary, [.handOff(.init(channel: .messages)), .later])
        XCTAssertEqual(card.signals.map(\.text), ["Job 1005", "14 Example Street", "25 min"])
        let draft = try XCTUnwrap(card.draft)
        XCTAssertEqual(draft.recipient, DraftRecipient(name: "Hana Example", addresses: ["555-0199"],
                                                      source: .jobCustomer))
        XCTAssertEqual(draft.text, "Hi Hana, it's Sam from Example Plumbing. On my way, there about 09:55.")
    }

    func testOnMyWaySignsWithWhatItHas() throws {
        let table: [(CardWearer, String)] = [
            (CardWearer(name: "Sam Example"), "Hi Hana, it's Sam. On my way, there about 09:55."),
            (CardWearer(company: "Example Plumbing"), "Hi Hana, on my way, there about 09:55."),
            (CardWearer(), "Hi Hana, on my way, there about 09:55."),
        ]
        for (wearer, text) in table {
            let card = rules.jobOnMyWay(F.jobInputs(wearer: wearer), now: F.at(9, 10), settings: settings)?.card
            XCTAssertEqual(card?.draft?.text, text)
        }
    }

    func testOnMyWayHasNoDraftWithoutANumberANameOrWhenTheOrganisationPinsTextsOff() throws {
        let noPhone = CardJob(id: F.job.id, jobReference: "1005", customer: "Hana Example",
                              address: "14 Example Street", phone: nil, scheduledFor: F.at(10))
        let noName = CardJob(id: F.job.id, jobReference: "1005", customer: nil,
                             address: "14 Example Street", phone: "555-0199", scheduledFor: F.at(10))
        var pinned = settings
        pinned.customerTextsAllowed = false
        for (inputs, settings) in [(F.jobInputs(job: noPhone), settings), (F.jobInputs(job: noName), settings),
                                   (F.jobInputs(), pinned)] {
            let card = try XCTUnwrap(rules.jobOnMyWay(inputs, now: F.at(9, 10), settings: settings)?.card)
            XCTAssertNil(card.draft)
            XCTAssertEqual(card.primary, .directions(destination: "14 Example Street", mode: .driving))
            XCTAssertEqual(card.secondary, [.later])
        }
    }

    func testOnMyWayNeedsATimeAnAddressAndTravelForThatJob() {
        let noAddress = CardJob(id: F.job.id, jobReference: "1005", customer: "Hana Example", address: nil,
                                phone: "555-0199", scheduledFor: F.at(10))
        let otherTravel = CardJobTravel(jobID: "someone-else", travelDuration: 600, leaveAt: F.at(9, 30),
                                        mode: .driving, distanceMeters: 5_000)
        XCTAssertNil(rules.jobOnMyWay(F.jobInputs(job: noAddress), now: F.at(9, 10), settings: settings))
        XCTAssertNil(rules.jobOnMyWay(F.jobInputs(travel: otherTravel), now: F.at(9, 10), settings: settings))
        XCTAssertNil(rules.jobOnMyWay(F.jobInputs(travel: nil), now: F.at(9, 10), settings: settings))
    }

    // MARK: - Running late to a job

    func testJobRunningLateAtTheBoundaries() {
        let table: [(Date, Double?, Bool)] = [
            (F.at(9, 33), 5_000, false),
            (F.at(9, 33, 1), 5_000, true),
            (F.at(9, 50), 300, false),
            (F.at(9, 50), 301, true),
            (F.at(9, 50), nil, false),
            (F.at(12), 5_000, false),  // past the job's window
        ]
        for (now, distance, appears) in table {
            XCTAssertEqual(rules.jobRunningLate(F.jobInputs(travel: F.jobTravel(distance: distance)), now: now,
                                                settings: settings) != nil,
                           appears, "at \(now), \(String(describing: distance)) m")
        }
    }

    func testJobRunningLateTextsTheCustomer() throws {
        let card = try XCTUnwrap(rules.jobRunningLate(F.jobInputs(), now: F.at(9, 50), settings: settings)?.card)
        XCTAssertEqual(card.urgency, .immediate)
        XCTAssertEqual(card.primary, .handOff(.init(channel: .messages)))
        // Arriving 10:15, fifteen minutes behind.
        XCTAssertEqual(card.draft?.text,
                       "Hi Hana, running about 15 minutes behind — there about 10:15. Sorry for the wait.")
        XCTAssertEqual(card.validUntil, F.at(12))
    }

    // MARK: - Report not sent, parts not ordered, sign-off owed

    func testReportOwedAppearsMoreThanFifteenMinutesAfterTheJobEnded() {
        let table: [(Date, Bool)] = [(F.at(14, 15), false), (F.at(14, 15, 1), true), (F.at(23, 59), true)]
        for (now, appears) in table {
            let inputs = F.jobInputs(sessions: [F.session("s1", ended: F.at(14))])
            XCTAssertEqual(!rules.jobReportOwed(inputs, now: now).isEmpty, appears, "at \(now)")
        }
    }

    func testReportOwedSkipsSentQueuedCancelledAndOpenJobs() {
        var queued = F.jobInputs(sessions: [F.session("s1", ended: F.at(14))])
        queued.jobs?.queuedReportSessionIDs = ["s1"]
        let cases: [CardInputs] = [
            F.jobInputs(sessions: [F.session("s1", ended: F.at(14), reportSent: true)]),
            F.jobInputs(sessions: [F.session("s1", ended: F.at(14), cancelled: true)]),
            F.jobInputs(sessions: [F.session("s1", ended: nil)]),
            F.jobInputs(sessions: [F.session("s1", ended: F.at(14, day: 11))]),
            queued,
        ]
        for inputs in cases {
            XCTAssertTrue(rules.jobReportOwed(inputs, now: F.at(16)).isEmpty)
        }
    }

    func testReportOwedOpensTheComposerAndAbsorbsTheJobDayRow() throws {
        let card = try XCTUnwrap(rules.jobReportOwed(F.jobInputs(sessions: [F.session("s1", ended: F.at(14))]),
                                                     now: F.at(16)).first?.card)
        XCTAssertEqual(card.primary, .openReport(sessionId: "s1"))
        XCTAssertEqual(card.secondary, [.openJob(id: "s1")])
        XCTAssertEqual(card.absorbs, [.jobDay("unsent-s1")])
        XCTAssertNil(card.draft)
        XCTAssertEqual(card.validUntil, F.at(0, day: 13))
    }

    func testPartsOwedNeedsUnsentRequests() throws {
        XCTAssertTrue(rules.jobPartsOwed(F.jobInputs(sessions: [F.session("s1", ended: nil)]), now: F.at(12)).isEmpty)
        let card = try XCTUnwrap(rules.jobPartsOwed(F.jobInputs(sessions: [F.session("s1", ended: nil, unsentParts: 2)]),
                                                    now: F.at(12)).first?.card)
        XCTAssertEqual(card.signals.last?.text, "2 parts")
        XCTAssertEqual(card.primary, .openPartsOrder(sessionId: "s1"))
        XCTAssertEqual(card.absorbs, [.jobDay("parts-s1")])
    }

    func testSignOffOwedOnlyWhenRequiredUnsignedAndTheReportHasNotGone() {
        let ended = F.at(14)
        let table: [(Bool, JobDaySession, Bool)] = [
            (true, F.session("s1", ended: ended), true),
            (false, F.session("s1", ended: ended), false),
            (true, F.session("s1", ended: ended, signedOff: true), false),
            (true, F.session("s1", ended: ended, reportSent: true), false),
            (true, F.session("s1", ended: nil), false),
        ]
        for (required, session, appears) in table {
            let cards = rules.jobSignOffOwed(F.jobInputs(sessions: [session], signOffRequired: required), now: F.at(15))
            XCTAssertEqual(!cards.isEmpty, appears)
            if appears {
                XCTAssertEqual(cards.first?.card.primary, .getSignOff(sessionId: "s1"))
                XCTAssertEqual(cards.first?.card.absorbs, [.jobDay("signoff-s1")])
            }
        }
    }

    func testNoJobCardsWithoutFieldAssistFacts() {
        let inputs = CardInputs(myDay: F.myDay())
        XCTAssertTrue(rules.cards(from: inputs, now: F.at(9, 10), settings: settings).isEmpty)
    }

    func testTheJobsContactBecomesItsNumberOnlyWhenItReadsAsOne() {
        let withNumber = UpcomingJob(jobReference: "1005", site: JobSite(customer: "Hana Example",
                                                                       address: "14 Example Street",
                                                                       contact: "555 0199"), origin: .typed)
        let withWords = UpcomingJob(jobReference: "1005", site: JobSite(customer: "Hana Example",
                                                                      contact: "ask at the desk"), origin: .typed)
        XCTAssertEqual(CardJob(withNumber).phone, "555 0199")
        XCTAssertNil(CardJob(withWords).phone)
        XCTAssertEqual(CardJob(withWords, officePhone: "555-0100").phone, "555-0100")
    }
}

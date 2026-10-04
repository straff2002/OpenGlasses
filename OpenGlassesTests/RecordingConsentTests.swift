import XCTest
@testable import OpenGlasses

/// What a person is told before a job is recorded, and when their saying so still stands.
final class RecordingConsentTests: XCTestCase {
    private typealias C = RecordingConsent

    private let given = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { given.addingTimeInterval(3_600) }

    // MARK: - The wording

    /// Each point the plan requires is made, in words a technician reads.
    func testTheSheetMakesEveryPointItMust() {
        let points = C.points()
        func says(_ words: String...) -> Bool {
            points.contains { point in words.allSatisfy { point.localizedCaseInsensitiveContains($0) } }
        }
        XCTAssertTrue(says("sound", "pictures", "recorded"), "sound and pictures are recorded")
        XCTAssertTrue(says("assistant", "replies", "heard"), "the assistant's replies may be heard")
        XCTAssertTrue(says("goes to your organisation's office"), "where it goes")
        XCTAssertTrue(says("faces are not blurred", "unless your organisation requires it"), "the blur")
        XCTAssertTrue(says("face blur setting", "does not change"), "the app's own blur switch does not govern it")
        XCTAssertTrue(says("tell the people nearby"), "the people nearby")
        XCTAssertTrue(says("stays on this phone", "7 days"), "how long it stays")
        XCTAssertTrue(says("can't be shared", "Photos", "report"), "it has no other way off the phone")
    }

    func testHowLongItStaysFollowsTheLimits() {
        var limits = RetentionDecision.Limits.standard
        limits.trimAfterAcknowledgement = 86_400
        XCTAssertTrue(C.points(limits: limits).contains { $0.contains("1 day after that") })
        limits.trimAfterAcknowledgement = 14 * 86_400
        XCTAssertTrue(C.points(limits: limits).contains { $0.contains("14 days after that") })
    }

    func testEveryLineIsPlainWords() {
        for line in C.points() + [C.title, C.acknowledgeTitle, C.reminder] {
            XCTAssertFalse(line.isEmpty)
            XCTAssertTrue(line.first?.isUppercase == true, line)
            // No plan letters, phase names or identifiers reach what a person reads.
            for token in ["Plan", "HE ", "P1", "P2", "FX", "GY", "bundle", "manifest", "sync", "_", "HIPAA"] {
                XCTAssertFalse(line.contains(token), "\(line) — \(token)")
            }
        }
        XCTAssertTrue(C.reminder.contains("Tell the people nearby"))
        XCTAssertTrue(C.reminder.contains("office"))
    }

    // MARK: - Whether it stands

    func testNoAcknowledgementIsNoConsent() {
        XCTAssertFalse(C.stands(nil, organizationID: "org-1", now: later))
    }

    func testAnAcknowledgementStandsForTheWordsAndTheOrganisationItWasGivenFor() {
        let acknowledgement = C.Acknowledgement(at: given, organizationID: "org-1")
        XCTAssertEqual(acknowledgement.wordingVersion, C.wordingVersion)
        XCTAssertTrue(C.stands(acknowledgement, organizationID: "org-1", now: later))
        XCTAssertTrue(C.stands(acknowledgement, organizationID: "org-1", now: given), "from the moment it is given")
    }

    func testAnotherOrganisationAsksAgain() {
        let acknowledgement = C.Acknowledgement(at: given, organizationID: "org-1")
        XCTAssertFalse(C.stands(acknowledgement, organizationID: "org-2", now: later),
                       "the words name the office the recording goes to")
    }

    func testAnOrganisationThatCannotBeNamedIsNoConsent() {
        let acknowledgement = C.Acknowledgement(at: given, organizationID: "")
        XCTAssertFalse(C.stands(acknowledgement, organizationID: "", now: later))
    }

    func testChangedWordsAskAgain() {
        let old = C.Acknowledgement(at: given, wordingVersion: C.wordingVersion - 1, organizationID: "org-1")
        XCTAssertFalse(C.stands(old, organizationID: "org-1", now: later))
        let newer = C.Acknowledgement(at: given, wordingVersion: C.wordingVersion + 1, organizationID: "org-1")
        XCTAssertFalse(C.stands(newer, organizationID: "org-1", now: later),
                       "words this version of the app has never shown were not agreed to here")
    }

    func testAnAcknowledgementDatedInTheFutureDoesNotStand() {
        let acknowledgement = C.Acknowledgement(at: later, organizationID: "org-1")
        XCTAssertFalse(C.stands(acknowledgement, organizationID: "org-1", now: given))
    }

    func testItIsKeptAndReadBackUnchanged() throws {
        let acknowledgement = C.Acknowledgement(at: given, organizationID: "org-1")
        let read = try JSONDecoder().decode(C.Acknowledgement.self, from: JSONEncoder().encode(acknowledgement))
        XCTAssertEqual(read, acknowledgement)
    }
}

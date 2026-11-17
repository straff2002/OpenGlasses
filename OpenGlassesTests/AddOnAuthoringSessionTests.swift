import XCTest
@testable import OpenGlasses

/// The building session's state machine: every transition, the caps, the shared repair budget, the
/// wall clock and the day a tested draft may wait.
final class AddOnAuthoringSessionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

    private func session(at phase: AddOnAuthoringSession.Phase) -> AddOnAuthoringSession {
        var s = AddOnAuthoringSession(id: "s", goal: "tide times at the coast", startedAt: t0)
        let path: [AddOnAuthoringSession.Event] = [
            .begin, .preflightPassed, .researchDone, .draftReceived, .validationPassed, .consentGiven,
            .testFinished, .assessmentPassed,
        ]
        let reach: [AddOnAuthoringSession.Phase: Int] = [
            .idle: 0, .preflight: 1, .researching: 2, .drafting: 3, .validating: 4,
            .awaitingTestConsent: 5, .testing: 6, .assessing: 7, .awaitingApproval: 8,
        ]
        for event in path.prefix(reach[phase] ?? 0) { XCTAssertTrue(s.handle(event, now: t0)) }
        XCTAssertEqual(s.phase, phase)
        return s
    }

    func testTheHappyPathVisitsEveryPhaseInOrder() {
        var s = session(at: .awaitingApproval)
        XCTAssertEqual(s.testedAt, t0)
        XCTAssertTrue(s.handle(.approved, now: t0))
        XCTAssertEqual(s.phase, .installed)
        XCTAssertNil(s.ending)
    }

    func testEventsThatDontFitThePhaseChangeNothing() {
        // No way from validating to testing except through consent.
        var s = session(at: .validating)
        XCTAssertFalse(s.handle(.consentGiven, now: t0))
        XCTAssertFalse(s.handle(.testFinished, now: t0))
        XCTAssertFalse(s.handle(.approved, now: t0))
        XCTAssertEqual(s.phase, .validating)
        // Nor straight from research to awaiting consent.
        var r = session(at: .researching)
        XCTAssertFalse(r.handle(.validationPassed, now: t0))
        XCTAssertEqual(r.phase, .researching)
        // Approval only from awaitingApproval.
        var a = session(at: .assessing)
        XCTAssertFalse(a.handle(.approved, now: t0))
    }

    func testPreflightCanEndTheSession() {
        var s = session(at: .preflight)
        XCTAssertTrue(s.handle(.preflightRefused(.covered("convert_currency")), now: t0))
        XCTAssertEqual(s.phase, .gaveUp)
        XCTAssertEqual(s.ending, .covered("convert_currency"))
        XCTAssertFalse(s.handle(.preflightPassed, now: t0), "a finished session stays finished")
    }

    func testDecliningConsentDiscardsAndTestingNeedsConsent() {
        var s = session(at: .awaitingTestConsent)
        XCTAssertFalse(s.spend(.test, now: t0), "no test while waiting for consent")
        XCTAssertTrue(s.handle(.consentDeclined, now: t0))
        XCTAssertEqual(s.phase, .discarded)
        XCTAssertEqual(s.ending, .consentDeclined)
    }

    func testRejectionAndCancel() {
        var s = session(at: .awaitingApproval)
        XCTAssertTrue(s.handle(.rejected, now: t0))
        XCTAssertEqual(s.ending, .rejected)

        var c = session(at: .testing)
        XCTAssertTrue(c.handle(.cancel, now: t0))
        XCTAssertEqual(c.phase, .discarded)
        XCTAssertEqual(c.ending, .cancelled)
        XCTAssertFalse(c.handle(.cancel, now: t0))
    }

    func testEndingEarlyForAKeyedService() {
        var s = session(at: .researching)
        XCTAssertTrue(s.handle(.end(.needsKey), now: t0))
        XCTAssertEqual(s.phase, .gaveUp)
        XCTAssertEqual(s.ending, .needsKey)
    }

    // MARK: - Repairs

    func testTwoRepairsAreSharedBetweenValidationAndTesting() {
        var s = session(at: .validating)
        XCTAssertTrue(s.handle(.validationFailed, now: t0))
        XCTAssertEqual(s.phase, .repairing)
        XCTAssertEqual(s.revision, 2)
        XCTAssertTrue(s.handle(.draftReceived, now: t0))
        XCTAssertTrue(s.handle(.validationPassed, now: t0))
        XCTAssertTrue(s.handle(.consentGiven, now: t0))
        XCTAssertTrue(s.spend(.test, now: t0))
        XCTAssertTrue(s.handle(.testFinished, now: t0))
        XCTAssertTrue(s.handle(.assessmentFailed, now: t0))
        XCTAssertEqual(s.phase, .repairing, "the second repair comes from the same budget")
        XCTAssertEqual(s.repairsLeft, 0)
        XCTAssertTrue(s.handle(.draftReceived, now: t0))
        XCTAssertTrue(s.handle(.validationFailed, now: t0))
        XCTAssertEqual(s.phase, .gaveUp)
        XCTAssertEqual(s.ending, .couldNotBuild)
    }

    func testAFailedTestWithNoRepairsLeftIsNotReliable() {
        var s = session(at: .validating)
        s.handle(.validationFailed, now: t0)
        s.handle(.draftReceived, now: t0)
        s.handle(.validationFailed, now: t0)
        s.handle(.draftReceived, now: t0)
        s.handle(.validationPassed, now: t0)
        s.handle(.consentGiven, now: t0)
        s.handle(.testFinished, now: t0)
        XCTAssertTrue(s.handle(.assessmentFailed, now: t0))
        XCTAssertEqual(s.ending, .notReliable)
    }

    // MARK: - Caps

    func testTenModelCallsThenTheSessionEnds() {
        var s = session(at: .researching)
        for _ in 0..<AddOnAuthoringSession.maxModelCalls { XCTAssertTrue(s.spend(.modelCall, now: t0)) }
        XCTAssertFalse(s.spend(.modelCall, now: t0))
        XCTAssertEqual(s.phase, .gaveUp)
        XCTAssertEqual(s.ending, .limitReached(.modelCall))
    }

    func testAFourthDocsFetchIsRefusedButTheSessionGoesOn() {
        var s = session(at: .researching)
        for _ in 0..<AddOnAuthoringSession.maxDocsFetches { XCTAssertTrue(s.spend(.docsFetch, now: t0)) }
        XCTAssertFalse(s.spend(.docsFetch, now: t0))
        XCTAssertEqual(s.phase, .researching)
        XCTAssertNil(s.ending)
    }

    func testDocsAreFetchedOnlyWhileResearching() {
        var s = session(at: .validating)
        s.handle(.validationFailed, now: t0)
        XCTAssertEqual(s.phase, .repairing)
        XCTAssertFalse(s.spend(.docsFetch, now: t0))
        XCTAssertTrue(s.spend(.modelCall, now: t0), "a repair may call the model")
    }

    func testOneTestPerRevision() {
        var s = session(at: .testing)
        XCTAssertTrue(s.spend(.test, now: t0))
        XCTAssertFalse(s.spend(.test, now: t0))
        XCTAssertEqual(s.ending, .limitReached(.test))
    }

    func testARepairIsANewRevisionWithItsOwnTest() {
        var s = session(at: .testing)
        XCTAssertTrue(s.spend(.test, now: t0))
        s.handle(.testFinished, now: t0)
        s.handle(.assessmentFailed, now: t0)
        s.handle(.draftReceived, now: t0)
        s.handle(.validationPassed, now: t0)
        XCTAssertEqual(s.phase, .awaitingTestConsent, "a repaired draft asks again before its test")
        s.handle(.consentGiven, now: t0)
        XCTAssertEqual(s.testsThisRevision, 0)
        XCTAssertTrue(s.spend(.test, now: t0))
    }

    // MARK: - Time

    func testTenMinutesOfBuildingIsTheLimit() {
        var s = session(at: .researching)
        let late = t0.addingTimeInterval(AddOnAuthoringSession.wallClock + 1)
        XCTAssertFalse(s.spend(.modelCall, now: late))
        XCTAssertEqual(s.ending, .tookTooLong)

        var t = session(at: .drafting)
        XCTAssertTrue(t.tick(now: late))
        XCTAssertEqual(t.ending, .tookTooLong)

        var e = session(at: .validating)
        XCTAssertFalse(e.handle(.validationPassed, now: late))
        XCTAssertEqual(e.phase, .gaveUp)
    }

    func testATestedDraftWaitsADayThenExpires() {
        var s = session(at: .awaitingApproval)
        // Waiting for the wearer is not building: the ten minutes don't apply.
        XCTAssertFalse(s.tick(now: t0.addingTimeInterval(AddOnAuthoringSession.wallClock + 60)))
        XCTAssertEqual(s.phase, .awaitingApproval)
        XCTAssertEqual(s.expiresAt, t0.addingTimeInterval(AddOnAuthoringSession.draftLifetime))
        XCTAssertTrue(s.tick(now: t0.addingTimeInterval(AddOnAuthoringSession.draftLifetime)))
        XCTAssertEqual(s.phase, .discarded)
        XCTAssertEqual(s.ending, .expired)
    }

    func testPhaseFlags() {
        XCTAssertEqual(AddOnAuthoringSession.Phase.allCases.filter(\.isTerminal), [.installed, .discarded, .gaveUp])
        XCTAssertFalse(AddOnAuthoringSession.Phase.awaitingApproval.isBuilding)
        XCTAssertFalse(AddOnAuthoringSession.Phase.idle.isBuilding)
        XCTAssertTrue(AddOnAuthoringSession.Phase.awaitingTestConsent.isBuilding)
    }
}

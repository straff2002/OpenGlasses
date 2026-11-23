import XCTest
@testable import OpenGlasses

/// Words a streaming live provider sends after the turn boundary belong to the turn that just
/// ended, not to the next one. Time is injected, so every case runs headlessly.
final class LateInputAttributionTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// A policy holding one finished turn that ended at `t0`.
    private func holding(_ wearer: String = "I have to go", replied: Bool = true,
                         generation: UInt64? = 4) -> LateInputAttribution {
        var policy = LateInputAttribution()
        let hold = policy.turnCompleted(wearer: wearer, modelReplied: replied,
                                        resetGeneration: generation, now: t0)
        XCTAssertNil(hold.finaliseFirst)
        return policy
    }

    func testTheGraceIsSixHundredMilliseconds() {
        XCTAssertEqual(LateInputAttribution.grace, 0.6, accuracy: 0.0001)
    }

    func testAFragmentInsideTheGraceIsJoinedToTheFinishedTurn() {
        var policy = holding()
        let token = policy.held?.token ?? -1

        XCTAssertEqual(policy.fragment(" bye", now: t0.addingTimeInterval(0.25)), .finishedTurn)
        XCTAssertEqual(policy.fragment(" now", now: t0.addingTimeInterval(0.4)), .finishedTurn)

        let turn = policy.graceElapsed(token: token)
        XCTAssertEqual(turn?.wearer, "I have to go bye now")
        XCTAssertEqual(turn?.lateFragments, 2)
        XCTAssertEqual(turn?.lateCharacters, 8)
        XCTAssertFalse(policy.isHolding)
    }

    func testAFragmentExactlyAtTheGraceStillBelongsToTheFinishedTurn() {
        var policy = holding()
        XCTAssertEqual(policy.fragment(" bye", now: t0.addingTimeInterval(LateInputAttribution.grace)),
                       .finishedTurn)
    }

    func testAFragmentAfterTheGraceIsTheNextTurnAndFinalisesTheHeldOneFirst() {
        var policy = holding()
        let token = policy.held?.token ?? -1

        let route = policy.fragment("what's the time", now: t0.addingTimeInterval(0.9))

        guard case .currentTurn(let finaliseFirst) = route else { return XCTFail("\(route)") }
        XCTAssertEqual(finaliseFirst?.wearer, "I have to go", "the held turn keeps only its own words")
        XCTAssertEqual(finaliseFirst?.lateFragments, 0)
        XCTAssertNil(policy.graceElapsed(token: token), "a turn is finalised once")
    }

    func testAFragmentWithNothingHeldIsTheCurrentTurn() {
        var policy = LateInputAttribution()
        XCTAssertEqual(policy.fragment("hello", now: t0), .currentTurn(finaliseFirst: nil))
    }

    func testANewTurnSignalFinalisesTheHeldTurnAtOnce() {
        var policy = holding()
        let token = policy.held?.token ?? -1
        _ = policy.fragment(" bye", now: t0.addingTimeInterval(0.1))

        let turn = policy.newTurnBegan()

        XCTAssertEqual(turn?.wearer, "I have to go bye")
        XCTAssertNil(policy.graceElapsed(token: token), "the grace timer finds nothing left to do")
        // Words after the new turn began are that turn's, however soon they come.
        XCTAssertEqual(policy.fragment("and another", now: t0.addingTimeInterval(0.2)),
                       .currentTurn(finaliseFirst: nil))
        XCTAssertNil(policy.newTurnBegan())
    }

    func testASecondBoundaryHandsBackTheEarlierTurnAndOnlyTheNewTimerFinalisesTheNewTurn() {
        var policy = holding("first")
        let firstToken = policy.held?.token ?? -1

        let second = policy.turnCompleted(wearer: "second", modelReplied: false,
                                          resetGeneration: nil, now: t0.addingTimeInterval(0.3))

        XCTAssertEqual(second.finaliseFirst?.wearer, "first")
        XCTAssertNotEqual(second.token, firstToken)
        XCTAssertNil(policy.graceElapsed(token: firstToken), "a stale timer cannot finalise the new turn")
        XCTAssertEqual(policy.graceElapsed(token: second.token)?.wearer, "second")
    }

    func testTheHeldTurnCarriesItsReplyFlagAndResetGeneration() {
        var policy = holding(replied: false, generation: 9)
        let token = policy.held?.token ?? -1
        let turn = policy.graceElapsed(token: token)
        XCTAssertEqual(turn?.modelReplied, false)
        XCTAssertEqual(turn?.resetGeneration, 9)
        XCTAssertEqual(turn?.endedAt, t0)
    }

    func testAllOfTheWordsMayArriveLate() {
        var policy = holding("")
        let token = policy.held?.token ?? -1
        _ = policy.fragment("new topic", now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(policy.graceElapsed(token: token)?.wearer, "new topic")
    }

    func testCJKFragmentsJoinWithoutASeam() {
        var policy = holding("你手里")
        let token = policy.held?.token ?? -1
        _ = policy.fragment(" 拿的", now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(policy.graceElapsed(token: token)?.wearer, "你手里拿的")
    }

    /// The stop flushes a held turn exactly once; nothing is left for a timer afterwards.
    func testSessionEndHandsBackTheHeldTurnOnce() {
        var policy = holding()
        let token = policy.held?.token ?? -1
        _ = policy.fragment(" bye", now: t0.addingTimeInterval(0.1))

        XCTAssertEqual(policy.sessionEnded()?.wearer, "I have to go bye")
        XCTAssertNil(policy.sessionEnded())
        XCTAssertNil(policy.graceElapsed(token: token))
        XCTAssertFalse(policy.isHolding)
    }
}

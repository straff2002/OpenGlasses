import XCTest
@testable import OpenGlasses

/// Plan GE P0 — when the conversation moves onto the phone, and when it is allowed back.
final class ConnectivityHandoffPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Entering the phone

    func testAnUnsatisfiedPathMovesToThePhoneAtOnce() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        XCTAssertEqual(policy.appliedRoute, .cloud)
        XCTAssertEqual(policy.handle(.pathUnsatisfied, now: at(1)), .phone)
        XCTAssertEqual(policy.state, .phone)
    }

    func testTwoConnectivityFailuresOnAPathThatClaimsToBeUpMoveToThePhone() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        XCTAssertNil(policy.handle(.connectivityFailure, now: at(1)), "one failure is not evidence")
        XCTAssertEqual(policy.state, .degraded(failures: 1))
        XCTAssertEqual(policy.handle(.connectivityFailure, now: at(2)), .phone)
        // The path never went down, so the return window starts at the moment of entry: the same
        // captive portal is not trusted again on the path alone.
        XCTAssertEqual(policy.state, .returning(windowStart: at(2)))
    }

    func testACloudSuccessBetweenFailuresClearsTheCount() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.connectivityFailure, now: at(1))
        policy.handle(.cloudSuccess, now: at(2))
        XCTAssertEqual(policy.state, .cloud)
        XCTAssertNil(policy.handle(.connectivityFailure, now: at(3)))
        XCTAssertEqual(policy.appliedRoute, .cloud)
    }

    func testStartingOfflineStartsOnThePhone() {
        let policy = ConnectivityHandoffPolicy(pathSatisfied: false, now: t0)
        XCTAssertEqual(policy.appliedRoute, .phone)
    }

    // MARK: - Returning

    func testReturnNeedsTwentyStableSecondsAndAProbe() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        XCTAssertNil(policy.handle(.pathSatisfied, now: at(10)))
        XCTAssertFalse(policy.isProbeDue(now: at(29)), "the stable window is 20 s")
        // A probe answer that arrives early is ignored — the window has not elapsed.
        XCTAssertNil(policy.handle(.probeSucceeded, now: at(25)))
        XCTAssertTrue(policy.isProbeDue(now: at(30)))
        XCTAssertEqual(policy.handle(.probeSucceeded, now: at(30)), .cloud)
        XCTAssertEqual(policy.state, .cloud)
    }

    func testAStablePathAloneNeverReturns() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        policy.handle(.pathSatisfied, now: at(1))
        XCTAssertNil(policy.endTurn())
        XCTAssertEqual(policy.appliedRoute, .phone, "only a probe takes it back")
    }

    func testAFailedProbeRestartsTheWindowAndBacksOff() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        policy.handle(.pathSatisfied, now: at(0))
        XCTAssertTrue(policy.isProbeDue(now: at(20)))
        policy.handle(.probeFailed, now: at(20))
        XCTAssertEqual(policy.state, .returning(windowStart: at(20)))
        XCTAssertEqual(policy.probeBackoff, 40)
        XCTAssertFalse(policy.isProbeDue(now: at(59)))
        XCTAssertTrue(policy.isProbeDue(now: at(60)))
        // A success right after the restart still needs the window: 40 s later it is fine.
        XCTAssertEqual(policy.handle(.probeSucceeded, now: at(60)), .cloud)
    }

    func testTheProbeBackoffDoublesToAFiveMinuteCap() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        policy.handle(.pathSatisfied, now: at(0))
        var backoffs: [TimeInterval] = []
        var now: TimeInterval = 0
        for _ in 0..<6 {
            now += 1000
            policy.handle(.probeFailed, now: at(now))
            backoffs.append(policy.probeBackoff)
        }
        XCTAssertEqual(backoffs, [40, 80, 160, 300, 300, 300])
    }

    func testARealDropResetsTheBackoff() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        policy.handle(.pathSatisfied, now: at(0))
        policy.handle(.probeFailed, now: at(20))
        policy.handle(.probeFailed, now: at(60))
        XCTAssertEqual(policy.probeBackoff, 80)
        policy.handle(.pathUnsatisfied, now: at(70))
        policy.handle(.pathSatisfied, now: at(80))
        XCTAssertEqual(policy.probeBackoff, 20)
        XCTAssertTrue(policy.isProbeDue(now: at(100)))
    }

    // MARK: - Never mid-turn

    func testNoSwitchMidTurn() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.beginTurn()
        XCTAssertNil(policy.handle(.pathUnsatisfied, now: at(1)), "the turn in flight finishes on its route")
        XCTAssertEqual(policy.appliedRoute, .cloud)
        XCTAssertEqual(policy.desiredRoute, .phone)
        XCTAssertTrue(policy.hasPendingChange)
        XCTAssertEqual(policy.endTurn(), .phone)
        XCTAssertFalse(policy.hasPendingChange)
    }

    func testAReturnWaitsForTheTurnBoundaryToo() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        policy.handle(.pathSatisfied, now: at(0))
        policy.beginTurn()
        XCTAssertNil(policy.handle(.probeSucceeded, now: at(25)))
        XCTAssertEqual(policy.appliedRoute, .phone)
        XCTAssertEqual(policy.endTurn(), .cloud)
    }

    // MARK: - Flapping

    func testFlappingNeverReturnsBeforeAStableWindow() {
        var policy = ConnectivityHandoffPolicy(now: t0)
        policy.handle(.pathUnsatisfied, now: at(0))
        var changes: [HandoffRoute] = []
        for second in stride(from: 1.0, to: 60.0, by: 5.0) {
            if let change = policy.handle(.pathSatisfied, now: at(second)) { changes.append(change) }
            XCTAssertFalse(policy.isProbeDue(now: at(second + 4)))
            if let change = policy.handle(.pathUnsatisfied, now: at(second + 4)) { changes.append(change) }
        }
        XCTAssertEqual(changes, [], "a link that keeps flapping stays on the phone")
        XCTAssertEqual(policy.appliedRoute, .phone)
    }

    func testTheDefaultsArePinned() {
        let tuning = ConnectivityHandoffPolicy.Tuning.standard
        XCTAssertEqual(tuning.failuresToEnterPhone, 2)
        XCTAssertEqual(tuning.returnStableSeconds, 20)
        XCTAssertEqual(tuning.initialProbeBackoff, 20)
        XCTAssertEqual(tuning.maxProbeBackoff, 300)
    }

    // MARK: - What counts as a connectivity failure

    func testOnlyNetworkErrorsCountAgainstTheCloud() {
        XCTAssertTrue(ConnectivityFailure.isConnectivityFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(ConnectivityFailure.isConnectivityFailure(URLError(.timedOut)))
        XCTAssertTrue(ConnectivityFailure.isConnectivityFailure(
            NSError(domain: NSURLErrorDomain, code: URLError.Code.cannotFindHost.rawValue)))
        XCTAssertFalse(ConnectivityFailure.isConnectivityFailure(URLError(.badServerResponse)))
        XCTAssertFalse(ConnectivityFailure.isConnectivityFailure(
            LLMError.apiError(provider: "x", statusCode: 429, message: "slow down")))
        XCTAssertFalse(ConnectivityFailure.isConnectivityFailure(CancellationError()))
    }
}

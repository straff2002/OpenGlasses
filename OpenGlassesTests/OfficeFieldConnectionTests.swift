import Foundation
import XCTest
@testable import OpenGlasses

/// Keeping a paired phone connected to its office while the app is open, driven through fakes for
/// the saved approval, the engine and the clock. The decisions themselves are
/// `OfficeFieldConnectionPolicy`'s and are checked directly at the end.
@MainActor
final class OfficeFieldConnectionTests: XCTestCase {
    private typealias Policy = OfficeFieldConnectionPolicy

    /// The fake world: what the saved approval says, how the engine answers, and what was asked.
    private final class World {
        var approval: Result<OfficeFieldConnection.Approved, Error> = .success(
            .init(transportPolicy: .automatic, lanHint: "tcp://192.168.1.24:22000", bindingSHA256: "first"))
        var startFailure: Error?
        var snapshot = World.snapshot(connected: false)
        var approvalChecks = 0
        var starts = 0
        /// The fake clock at each engine start, in seconds after the test began.
        var startTimes: [TimeInterval] = []
        var stops = 0
        /// How often the connection asked for what the office has sent to be taken in.
        var takeIns = 0
        /// Every pause the connection asked for, in seconds.
        var sleeps: [TimeInterval] = []
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var pausesMoveTheClock = true

        static func snapshot(running: Bool = true, connected: Bool, type: String = "", local: Bool? = nil) -> String {
            let localField = local.map { #","observedConnectionLocal":\#($0)"# } ?? ""
            return #"{"running":\#(running),"managedOffice":true,"connected":\#(connected),"observedConnectionType":"\#(type)"\#(localField)}"#
        }
    }

    private struct Unreachable: Error {}

    private var world = World()

    private func makeConnection(enabled: Bool = true) -> OfficeFieldConnection {
        let world = world
        var seams = OfficeFieldConnection.Seams()
        seams.approvedOffice = {
            world.approvalChecks += 1
            return try world.approval.get()
        }
        seams.start = {
            if let failure = world.startFailure { throw failure }
            world.starts += 1
            world.startTimes.append(world.now.timeIntervalSince1970 - 1_800_000_000)
        }
        seams.stop = { world.stops += 1 }
        seams.snapshot = { world.snapshot }
        seams.takeIn = { world.takeIns += 1 }
        // Each pause moves the fake clock on by what was asked, and takes a moment of real time.
        // Recorded on the main actor as the run asks, so a replaced run records nothing more.
        seams.sleep = { @MainActor nanoseconds in
            let seconds = TimeInterval(nanoseconds) / 1_000_000_000
            world.sleeps.append(seconds)
            if world.pausesMoveTheClock { world.now = world.now.addingTimeInterval(seconds) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        seams.clock = { world.now }
        return OfficeFieldConnection(enabled: enabled, seams: seams)
    }

    private func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in time", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Starting and stopping

    func testNoApprovalNeverStartsTheEngine() async {
        world.approval = .failure(OfficePairingService.Refusal.noApprovedOffice)
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { connection.state == .stopped(.notPaired) }
        XCTAssertEqual(world.starts, 0)
        XCTAssertEqual(world.approvalChecks, 1, "a refused approval is not retried on its own")
    }

    func testWhatTheOfficeSentIsTakenInOnlyWhileTheEngineRuns() async {
        let connection = makeConnection()
        connection.appBecameActive()
        // Waiting for the office still takes in: a job committed earlier is on the phone already.
        await waitUntil { world.takeIns >= 2 }
        XCTAssertEqual(connection.state, .waiting(.automatic))
        connection.appEnteredBackground()
        await waitUntil { world.stops >= 2 }
        let taken = world.takeIns
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.takeIns, taken, "nothing is taken in once the engine has stopped")

        world.approval = .failure(OfficePairingService.Refusal.inactiveLease)
        world.takeIns = 0
        connection.appBecameActive()
        await waitUntil { connection.state == .stopped(.managementLapsed) }
        XCTAssertEqual(world.takeIns, 0, "and nothing on an approval that no longer verifies")
    }

    func testABuildWithoutTheTransportDoesNothing() async throws {
        let connection = makeConnection(enabled: false)
        connection.appBecameActive()
        connection.networkBecameAvailable()
        try await Task.sleep(nanoseconds: 20_000_000)
        connection.appEnteredBackground()
        XCTAssertEqual(connection.state, .unavailable)
        XCTAssertNil(Policy.status(connection.state), "no row without the office transport")
        XCTAssertEqual(world.approvalChecks, 0)
        XCTAssertEqual(world.starts, 0)
        XCTAssertEqual(world.stops, 0)
        do {
            try await connection.restart()
            XCTFail("nothing starts without the transport")
        } catch {
            XCTAssertEqual(error as? OfficeFieldConnection.NotStarted, .notRunning)
        }
    }

    func testWaitsUnderTheApprovalsPolicyThenShowsTheRoute() async {
        world.approval = .success(.init(transportPolicy: .privateLan, lanHint: "tcp://192.168.1.24:22000",
                                        bindingSHA256: "first"))
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { connection.state == .waiting(.privateLan) }
        XCTAssertEqual(world.starts, 1)
        world.snapshot = World.snapshot(connected: true, type: "tcp-client")
        await waitUntil { connection.state == .connected(.direct) }
        world.snapshot = World.snapshot(connected: true, type: "relay-client")
        await waitUntil { connection.state == .connected(.relay) }
        world.snapshot = World.snapshot(connected: false)
        await waitUntil { connection.state == .waiting(.privateLan) }
        XCTAssertEqual(world.starts, 1, "polling the engine does not restart it")
        connection.appEnteredBackground()
    }

    func testOfficeNetworkOnlyWithNoAddressStopsAndSaysSo() async {
        world.approval = .success(.init(transportPolicy: .privateLan, lanHint: nil, bindingSHA256: "first"))
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { connection.state == .stopped(.noOfficeAddress) }
        XCTAssertEqual(world.starts, 0)
    }

    func testAnApprovalThatStopsVerifyingStopsTheConnection() async {
        let connection = makeConnection()
        connection.appBecameActive()
        world.snapshot = World.snapshot(connected: true, type: "quic-client")
        await waitUntil { connection.state == .connected(.direct) }
        let stopsWhileRunning = world.stops
        // The 30-day pairing lapses: the next check (every 30 s) finds it.
        world.approval = .failure(OfficePeerBinding.Refusal.notCurrentlyValid)
        await waitUntil { connection.state == .stopped(.pairingExpired) }
        XCTAssertEqual(world.stops, stopsWhileRunning + 1, "the engine is stopped")
        XCTAssertEqual(Policy.status(connection.state)?.detail, "Pair this phone again at the office.")
        let starts = world.starts
        // Coming back to the app checks again, and stays stopped while the pairing is still lapsed.
        connection.appEnteredBackground()
        connection.appBecameActive()
        await waitUntil { connection.state == .stopped(.pairingExpired) }
        XCTAssertEqual(world.starts, starts)
    }

    func testALapsedLeaseStopsTheConnection() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { connection.state == .waiting(.automatic) }
        world.approval = .failure(OfficePairingService.Refusal.inactiveLease)
        await waitUntil { connection.state == .stopped(.managementLapsed) }
        XCTAssertEqual(Policy.status(connection.state)?.detail, "Pair this phone again at the office.")
    }

    func testAReplacedApprovalRestartsTheEngine() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 }
        world.approval = .success(.init(transportPolicy: .automatic, lanHint: "tcp://192.168.1.24:22000",
                                        bindingSHA256: "second"))
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
    }

    func testARenewedBindingIsNoticedOnTheNextPollNotTheNextInterval() async {
        world.pausesMoveTheClock = false   // the 30-second recheck never comes due by itself
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 && world.takeIns > 0 }
        let checksBefore = world.approvalChecks
        world.approval = .success(.init(transportPolicy: .automatic, lanHint: "tcp://192.168.1.24:22000",
                                        bindingSHA256: "renewed"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.starts, 1, "nothing rechecks the approval before the interval")
        XCTAssertEqual(world.approvalChecks, checksBefore)
        // The check-in service says the saved binding was replaced: the folders start again.
        connection.approvalChanged()
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
    }

    func testTheBackgroundStopsTheEngineAndTheForegroundStartsIt() async {
        let connection = makeConnection()
        connection.appBecameActive()
        connection.appBecameActive()   // launch and the first activation: one start
        await waitUntil { world.starts == 1 }
        connection.appEnteredBackground()
        XCTAssertEqual(connection.state, .paused)
        await waitUntil { world.stops >= 2 }   // the run's stop before starting, then the background's
        let polls = world.sleeps.count
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.sleeps.count, polls, "nothing runs in the background")
        XCTAssertEqual(world.starts, 1)
        connection.appBecameActive()
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
    }

    func testAnEngineThatStopsByItselfIsStartedAgain() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 }
        world.snapshot = World.snapshot(running: false, connected: false)
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
    }

    // MARK: - Backoff

    func testStartFailuresBackOffToAMinute() async {
        world.startFailure = Unreachable()
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.sleeps.count >= 8 }
        XCTAssertEqual(Array(world.sleeps.prefix(8)), [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(connection.state, .waiting(.automatic))
        connection.appEnteredBackground()
    }

    func testTheForegroundResetsTheBackoff() async {
        world.startFailure = Unreachable()
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.sleeps.count >= 4 }
        connection.appEnteredBackground()
        world.sleeps = []
        connection.appBecameActive()
        await waitUntil { world.sleeps.count >= 2 }
        XCTAssertEqual(Array(world.sleeps.prefix(2)), [2, 4])
        connection.appEnteredBackground()
    }

    func testTheNetworkReturningRestartsAConnectionThatHasNotReachedTheOffice() async {
        world.startFailure = Unreachable()
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.sleeps.count >= 4 }   // 2 + 4 + 8 s without the office
        world.startFailure = nil
        world.sleeps = []
        connection.networkBecameAvailable()
        await waitUntil { world.starts == 1 }
        XCTAssertFalse(world.sleeps.contains(16), "the backoff starts again from the beginning")
        // Once connected, the network returning changes nothing.
        world.snapshot = World.snapshot(connected: true, type: "relay-server")
        await waitUntil { connection.state == .connected(.relay) }
        connection.networkBecameAvailable()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.starts, 1)
        connection.appEnteredBackground()
    }

    func testTheNetworkReturningLeavesAJustStartedConnectionAlone() async {
        world.pausesMoveTheClock = false   // no time passes: it has only just started
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 }
        connection.networkBecameAvailable()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.starts, 1)
        connection.appEnteredBackground()
    }

    // MARK: - Looking the office up again

    func testFromAnywhereLooksTheOfficeUpAgainAfterAMinuteThenEveryTwo() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 3 }
        connection.appEnteredBackground()
        XCTAssertEqual(world.startTimes, [0, 60, 180])
        XCTAssertFalse(world.sleeps.contains(2), "looking again is not a failure: no backoff")
        XCTAssertEqual(connection.state, .paused)
    }

    func testAConnectedPhoneNeverRestartsToLookAgain() async {
        world.snapshot = World.snapshot(connected: true, type: "relay-client")
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.now.timeIntervalSince1970 - 1_800_000_000 > 400 }
        XCTAssertEqual(connection.state, .connected(.relay))
        XCTAssertEqual(world.starts, 1)
        connection.appEnteredBackground()
    }

    func testOfficeNetworkOnlyDoesNotRestartToLookAgain() async {
        world.approval = .success(.init(transportPolicy: .privateLan, lanHint: "tcp://192.168.1.24:22000",
                                        bindingSHA256: "first"))
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.now.timeIntervalSince1970 - 1_800_000_000 > 400 }
        XCTAssertEqual(connection.state, .waiting(.privateLan))
        XCTAssertEqual(world.starts, 1)
        connection.appEnteredBackground()
    }

    func testLosingTheOfficeStartsTheMinuteAgain() async {
        world.snapshot = World.snapshot(connected: true, type: "tcp-client")
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.now.timeIntervalSince1970 - 1_800_000_000 >= 300 }
        world.snapshot = World.snapshot(connected: false)
        let lost = world.now.timeIntervalSince1970 - 1_800_000_000
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
        XCTAssertEqual(world.startTimes.count, 2)
        let gap = world.startTimes[1] - lost
        XCTAssertGreaterThanOrEqual(gap, 60, "a minute after the office was lost, not two")
        XCTAssertLessThanOrEqual(gap, 66)
    }

    // MARK: - Others that need the engine

    func testSuspendingForThePairingScreenBlocksUntilResumed() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 }
        await connection.suspend()
        XCTAssertEqual(connection.state, .paused)
        let stops = world.stops
        XCTAssertGreaterThanOrEqual(stops, 2, "the engine has stopped by the time suspend returns")
        // Coming back to the app while the pairing screen is open does not take the engine back.
        connection.appEnteredBackground()
        connection.appBecameActive()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(world.starts, 1)
        connection.resume()
        await waitUntil { world.starts == 2 }
        connection.appEnteredBackground()
    }

    func testRestartAfterJoiningStartsAgainFromTheSavedApproval() async throws {
        let connection = makeConnection()
        connection.appBecameActive()
        await waitUntil { world.starts == 1 }
        try await connection.restart()
        XCTAssertEqual(world.starts, 2)
        XCTAssertGreaterThanOrEqual(world.approvalChecks, 2)
        connection.appEnteredBackground()
    }

    func testRestartSaysWhenTheApprovalIsRefused() async {
        world.approval = .failure(OfficePairingService.Refusal.noApprovedOffice)
        let connection = makeConnection()
        connection.appBecameActive()
        do {
            try await connection.restart()
            XCTFail("an approval that does not verify starts nothing")
        } catch {
            XCTAssertEqual(error as? OfficeFieldConnection.StoppedError, .init(reason: .notPaired))
        }
        XCTAssertEqual(world.starts, 0)
    }

    func testRestartWhileThePairingScreenHasTheEngineStartsNothing() async {
        let connection = makeConnection()
        connection.appBecameActive()
        await connection.suspend()
        do {
            try await connection.restart()
            XCTFail("the pairing screen has the engine")
        } catch {
            XCTAssertEqual(error as? OfficeFieldConnection.NotStarted, .notRunning)
        }
        XCTAssertEqual(world.starts, 0)
    }

    // MARK: - The decisions

    func testRouteMapping() {
        XCTAssertEqual(Policy.route(connectionType: "tcp-client"), .direct)
        XCTAssertEqual(Policy.route(connectionType: "tcp-server"), .direct)
        XCTAssertEqual(Policy.route(connectionType: "quic-client"), .direct)
        XCTAssertEqual(Policy.route(connectionType: "relay-client"), .relay)
        XCTAssertEqual(Policy.route(connectionType: "relay-server"), .relay)
        XCTAssertNil(Policy.route(connectionType: ""))
        XCTAssertNil(Policy.route(connectionType: "tcp"))

        XCTAssertEqual(Policy.observe(snapshot: World.snapshot(connected: true, type: "relay-client")), .connected(.relay))
        XCTAssertEqual(Policy.observe(snapshot: World.snapshot(connected: true, type: "tcp-server")), .connected(.direct))
        XCTAssertEqual(Policy.observe(snapshot: World.snapshot(connected: true, type: "")), .waiting)
        XCTAssertEqual(Policy.observe(snapshot: World.snapshot(connected: false, type: "tcp-client")), .waiting)
        XCTAssertEqual(Policy.observe(snapshot: World.snapshot(running: false, connected: false)), .notRunning)
        XCTAssertEqual(Policy.observe(snapshot: #"{"running":true,"managedOffice":false,"connected":true}"#), .notRunning)
        XCTAssertEqual(Policy.observe(snapshot: "not json"), .notRunning)
    }

    func testLookingAgainSchedule() {
        let since = Date(timeIntervalSince1970: 1_000)
        func looks(_ policy: OfficePairingService.TransportPolicy, after seconds: TimeInterval,
                   lastLooked: TimeInterval? = nil) -> Bool {
            Policy.restartsToLookAgain(policy: policy, notConnectedSince: since,
                                       lastLookedAgain: lastLooked.map { since.addingTimeInterval($0) },
                                       now: since.addingTimeInterval(seconds))
        }
        XCTAssertFalse(looks(.automatic, after: 59))
        XCTAssertTrue(looks(.automatic, after: 60))
        XCTAssertFalse(looks(.automatic, after: 179, lastLooked: 60))
        XCTAssertTrue(looks(.automatic, after: 180, lastLooked: 60))
        XCTAssertFalse(looks(.privateLan, after: 3_600))
        XCTAssertFalse(Policy.restartsToLookAgain(policy: .automatic, notConnectedSince: nil,
                                                  lastLookedAgain: nil, now: since.addingTimeInterval(3_600)),
                       "connected: never")
    }

    func testBackoffSchedule() {
        XCTAssertEqual((1...8).map(Policy.backoff(afterFailures:)), [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(Policy.backoff(afterFailures: 0), 0)
        XCTAssertEqual(Policy.backoff(afterFailures: 1_000), 60)
    }

    func testWhichFailuresStopTheConnection() {
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.noDesktopEnrolment), .stop(.notPaired))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.noApprovedOffice), .stop(.notPaired))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.inactiveLease), .stop(.managementLapsed))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.missingLicence), .stop(.managementLapsed))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.approvalSuperseded), .stop(.pairingReplaced))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.noOfficeAddress), .stop(.noOfficeAddress))
        XCTAssertEqual(Policy.afterFailure(OfficePairingService.Refusal.changedDuringApproval), .retry)
        XCTAssertEqual(Policy.afterFailure(OfficePeerBinding.Refusal.notCurrentlyValid), .stop(.pairingExpired))
        XCTAssertEqual(Policy.afterFailure(OfficePeerBinding.Refusal.profileExpired), .stop(.pairingExpired))
        XCTAssertEqual(Policy.afterFailure(OfficePeerBinding.Refusal.rollback), .stop(.pairingReplaced))
        XCTAssertEqual(Policy.afterFailure(OfficePeerBinding.Refusal.wrongPeer), .stop(.pairingInvalid))
        XCTAssertEqual(Policy.afterFailure(OfficeInlineEntitlement.Refusal.notCurrentlyValid), .stop(.managementLapsed))
        XCTAssertEqual(Policy.afterFailure(OfficeInlineEntitlement.Refusal.untrustedLicence), .stop(.pairingInvalid))
        XCTAssertEqual(Policy.afterFailure(OfficeApprovedPeerStore.Refusal.corruptState), .stop(.pairingInvalid))
        XCTAssertEqual(Policy.afterFailure(Unreachable()), .retry, "an engine that will not start is tried again")
    }

    func testWhatThePhoneSays() {
        XCTAssertEqual(Policy.status(.connected(.direct))?.title, "Connected to office — direct")
        XCTAssertEqual(Policy.status(.connected(.relay))?.title, "Connected to office — via relay")
        XCTAssertEqual(Policy.status(.waiting(.automatic))?.title, "Waiting for the office")
        XCTAssertEqual(Policy.status(.waiting(.privateLan))?.title, "Office network only — waiting")
        XCTAssertEqual(Policy.status(.waiting(.privateLan))?.detail,
                       "This organisation connects on the office network only.")
        for reason: Policy.StopReason in [.pairingExpired, .managementLapsed, .pairingReplaced, .pairingInvalid] {
            XCTAssertEqual(Policy.status(.stopped(reason))?.detail, "Pair this phone again at the office.")
        }
        XCTAssertNil(Policy.status(.unavailable))
    }

    /// The phone is on its office's own network only when the engine says the connection is
    /// direct and local. A relay, the internet, or a snapshot that does not say, is not.
    func testOnTheOfficesOwnNetworkOnlyWhenTheEngineSaysDirectAndLocal() {
        XCTAssertTrue(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: true, type: "tcp-client", local: true)))
        XCTAssertTrue(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: true, type: "quic-client", local: true)))
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: true, type: "tcp-client", local: false)))
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: true, type: "tcp-client")),
                       "an engine that does not say is not taken to be local")
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: true, type: "relay-client", local: true)))
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: World.snapshot(connected: false, type: "tcp-client", local: true)))
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: World.snapshot(running: false, connected: true, type: "tcp-client", local: true)))
        XCTAssertFalse(Policy.onOfficeNetwork(snapshot: "not json"))
        XCTAssertFalse(Policy.onOfficeNetwork(
            snapshot: #"{"running":true,"managedOffice":true,"connected":true,"observedConnectionType":"tcp-client","observedConnectionLocal":"true"}"#))
    }
}

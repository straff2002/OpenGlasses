import XCTest
@testable import OpenGlasses

/// Plan MZ §4 — the sync machine over `MockRingTransport`: the connect sequence, echo-as-ack with
/// one retry, the sleep quiet window, the stored-history watchdog, measurements and their caps, a
/// measurement during a sync, and disconnects.
final class RingSyncMachineTests: XCTestCase {

    private typealias F = RingFixture

    /// The moment the protocol's time-sync example stands for, at −4 h.
    private let start = Date(timeIntervalSince1970: 1_779_832_030)
    private let minusFour = TimeZone(secondsFromGMT: -4 * 3600)!

    private func ring(stepGoal: Int? = 10_000, latchedClock: RingClock? = nil,
                      timeZone: TimeZone? = nil) -> MockRingTransport {
        let configuration = RingSyncMachine.Configuration(timeZone: timeZone ?? minusFour, stepGoal: stepGoal)
        return MockRingTransport(configuration: configuration, latchedClock: latchedClock, now: start)
    }

    /// A ring that has finished its connect sync and is idle.
    private func idleRing() -> MockRingTransport {
        let ring = ring()
        ring.connect()
        ring.settle()
        XCTAssertEqual(ring.machine.phase, .idle)
        ring.clearRecords()
        return ring
    }

    private func sleepRuns(in reports: [RingSyncReport]) -> [RingSleepRun] {
        reports.flatMap { report -> [RingSleepRun] in
            if case .sleep(let runs) = report { return runs }
            return []
        }
    }

    // MARK: - The connect sequence

    func testTheFullSequence() throws {
        let ring = ring()
        ring.responses[0x10] = [F.sleepPacket(at: F.sleepLight0130, all: F.light),
                                F.sleepPacket(at: F.sleepLight0130 + 900, all: F.deep)]
        ring.responses[0x16] = [F.packet("16f0"), F.packet("16aa"), F.packet("16a0"), F.packet("16a0"),
                                F.packet("16ff")]
        // The burst after subscribing brings the current activity.
        ring.connect(burst: [F.activityExample])
        ring.settle()

        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21, 0x19, 0x1a, 0x10, 0x16])
        XCTAssertEqual(ring.written[1], F.hex("019edc156afc0000000000000000000000000000"),
                       "the time sync is the protocol's own example at this moment and zone")
        XCTAssertEqual(ring.written[2], F.hex("21656e2d55530000000000000000000000000000"))
        XCTAssertEqual(ring.written[3], F.hex("190000173b011e02000000000000000000000000"),
                       "every 30 minutes, the recommended schedule")
        XCTAssertEqual(ring.written[4], F.hex("1a10270000000000000000000000000000000000"))
        XCTAssertFalse(ring.writtenOpcodes.contains(0x02), "the body profile is never sent")
        XCTAssertEqual(ring.batteryReads, 1)

        XCTAssertEqual(ring.reports.first, .syncStarted)
        XCTAssertTrue(ring.reports.contains(.clockLatched(RingClock(offsetSeconds: -4 * 3600))))
        XCTAssertTrue(ring.reports.contains(.battery(percent: 80)))
        XCTAssertTrue(ring.reports.contains(.activity(steps: 328, at: start)))
        XCTAssertEqual(sleepRuns(in: ring.reports).map(\.stage), [.asleepCore, .asleepDeep])
        XCTAssertTrue(ring.reports.contains(.storedHistory(chunks: 2, complete: true)))
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
        XCTAssertFalse(ring.reports.contains { if case .stepSkipped = $0 { return true }; return false })
        XCTAssertEqual(ring.machine.phase, .idle)
        XCTAssertEqual(ring.machine.latchedClock, RingClock(offsetSeconds: -4 * 3600))
    }

    func testWithoutAStepGoalTheGoalStepIsLeftOut() {
        let ring = ring(stepGoal: nil)
        ring.connect()
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21, 0x19, 0x10, 0x16])
    }

    func testWithoutAnActivityInTheBurstTheSyncWaitsForOneThenMovesOn() {
        let ring = ring()
        ring.connect()
        ring.advance(by: 1)
        XCTAssertEqual(ring.machine.phase, .syncing(.activity))
        ring.notify(F.activityExample)
        XCTAssertEqual(ring.machine.phase, .syncing(.sleep))

        let quiet = self.ring()
        quiet.connect()
        quiet.advance(by: 1)
        XCTAssertEqual(quiet.machine.phase, .syncing(.activity))
        quiet.advance(by: 5)
        XCTAssertNotEqual(quiet.machine.phase, .syncing(.activity), "five seconds without one: on to sleep")
        XCTAssertFalse(quiet.reports.contains { if case .activity = $0 { return true }; return false })
    }

    // MARK: - Echo as acknowledgement

    func testAMissingEchoIsRetriedOnceThenSkipped() {
        let ring = ring()
        ring.silentOpcodes = [0x21]
        ring.connect()
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21])
        ring.advance(by: 2.9)
        XCTAssertEqual(ring.writtenOpcodes.count, 3, "no retry before 3 s")
        ring.advance(by: 0.2)
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21, 0x21], "one retry")
        ring.advance(by: 3)
        XCTAssertTrue(ring.reports.contains(.stepSkipped(.locale)))
        XCTAssertEqual(Array(ring.writtenOpcodes.prefix(6)), [0x0c, 0x01, 0x21, 0x21, 0x19, 0x1a],
                       "the sync carries on")
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes.filter { $0 == 0x21 }.count, 2, "never a third try")
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
    }

    func testAnEchoOnTheRetryIsEnough() {
        let ring = ring()
        ring.silentOpcodes = [0x19]
        ring.connect()
        ring.advance(by: 3)
        XCTAssertEqual(ring.writtenOpcodes.last, 0x19)
        ring.notify(F.hex("190000173b011e02000000000000000000000000"))
        XCTAssertEqual(ring.writtenOpcodes.last, 0x1a)
        XCTAssertFalse(ring.reports.contains(.stepSkipped(.schedule)))
    }

    func testABatteryReadThatNeverAnswersIsSkipped() {
        let ring = ring()
        ring.answersBattery = false
        ring.connect()
        ring.settle()
        XCTAssertEqual(ring.batteryReads, 2)
        XCTAssertTrue(ring.reports.contains(.stepSkipped(.battery)))
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
    }

    func testATimeSyncWithNoEchoLatchesNothing() {
        let ring = ring()
        ring.silentOpcodes = [0x01]
        ring.connect()
        ring.settle()
        XCTAssertTrue(ring.reports.contains(.stepSkipped(.time)))
        XCTAssertFalse(ring.reports.contains { if case .clockLatched = $0 { return true }; return false })
        XCTAssertNil(ring.machine.latchedClock)
    }

    // MARK: - Sleep and stored history

    func testSleepEndsAfterTwoQuietSeconds() {
        let ring = ring()
        ring.connect()
        ring.notify(F.activityExample)
        XCTAssertEqual(ring.machine.phase, .syncing(.sleep))
        ring.advance(by: 1.5)
        ring.notify(F.sleepPacket(at: F.sleepLight0130, all: F.light))
        ring.advance(by: 1.5)
        ring.notify(F.sleepPacket(at: F.sleepLight0130 + 900, all: F.light))
        ring.advance(by: 1.9)
        XCTAssertEqual(ring.machine.phase, .syncing(.sleep), "each packet restarts the window")
        ring.advance(by: 0.2)
        XCTAssertEqual(ring.machine.phase, .syncing(.storedHistory))
        XCTAssertEqual(sleepRuns(in: ring.reports).first?.duration, 30 * 60)
    }

    func testANightWithNoSleepReportsNoRuns() {
        let ring = ring()
        ring.connect()
        ring.settle()
        XCTAssertTrue(sleepRuns(in: ring.reports).isEmpty)
        XCTAssertFalse(ring.reports.contains { if case .sleep = $0 { return true }; return false })
    }

    func testStoredHistoryWithoutItsEndMarkerStopsOnTheWatchdog() {
        let ring = ring()
        ring.responses[0x16] = [F.packet("16f0"), F.packet("16a0")]
        ring.connect()
        ring.notify(F.activityExample)
        ring.advance(by: 2)
        XCTAssertEqual(ring.machine.phase, .syncing(.storedHistory))
        ring.advance(by: 9.9)
        XCTAssertEqual(ring.machine.phase, .syncing(.storedHistory))
        ring.notify(F.packet("16a0"))
        ring.advance(by: 9.9)
        XCTAssertEqual(ring.machine.phase, .syncing(.storedHistory), "a chunk restarts the watchdog")
        ring.advance(by: 0.2)
        XCTAssertTrue(ring.reports.contains(.storedHistory(chunks: 2, complete: false)))
        XCTAssertTrue({ if case .syncFinished = ring.reports.last { return true }; return false }())
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    /// A night recorded under the clock the ring had before this connection is decoded with that
    /// clock, even though the sync has just set a new one.
    func testSleepIsDecodedWithTheClockItWasRecordedUnder() throws {
        let old = RingClock(offsetSeconds: 3600)
        let ring = ring(latchedClock: old, timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
        let asleepAt = Date(timeIntervalSince1970: 1_779_926_400)
        ring.responses[0x10] = [F.sleepPacket(at: old.ringSeconds(for: asleepAt), all: F.light)]
        ring.connect()
        ring.settle()
        XCTAssertTrue(ring.reports.contains(.clockLatched(RingClock(offsetSeconds: 3 * 3600))))
        XCTAssertEqual(sleepRuns(in: ring.reports).first?.start, asleepAt)
        XCTAssertEqual(ring.machine.recordingClock, RingClock(offsetSeconds: 3 * 3600),
                       "once the sync has fetched everything, the new clock is the recording clock")
    }

    func testATimeZoneChangeWhileIdleSetsOnlyTheClock() {
        let ring = idleRing()
        ring.send(.timeZoneChanged(TimeZone(secondsFromGMT: 19_800)!))
        XCTAssertEqual(ring.writtenOpcodes, [0x01])
        XCTAssertEqual(ring.written[0][5], 0x05)
        XCTAssertTrue(ring.reports.contains(.clockLatched(RingClock(offsetSeconds: 19_800))))
        XCTAssertFalse(ring.reports.contains { if case .syncFinished = $0 { return true }; return false })
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    func testSyncNowRunsTheWholeSequenceAgain() {
        let ring = idleRing()
        ring.send(.syncNow)
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21, 0x19, 0x1a, 0x10, 0x16])
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
    }

    // MARK: - Live heart rate

    func testALiveSessionStreamsRestartsWhenTheRingEndsItAndStopsOnRequest() {
        let ring = idleRing()
        let t0 = ring.now
        ring.send(.measure(.liveHeartRate))
        XCTAssertEqual(ring.written, [F.packet("14b4")])
        XCTAssertEqual(ring.machine.phase, .measuring(.liveHeartRate))
        ring.notify(F.hex("14bbec146a500000000000000000000000000000"))
        ring.advance(by: 1)
        ring.notify(F.hex("14c0ec146a510000000000000000000000000000"))
        ring.notify(F.packet("14bbec146a00"))  // zero: not plausible, dropped
        XCTAssertEqual(ring.reports, [.heartRate(bpm: 80, at: t0, during: .liveHeartRate),
                                      .heartRate(bpm: 81, at: t0.addingTimeInterval(1), during: .liveHeartRate)])

        ring.notify(F.packet("27"))
        XCTAssertEqual(ring.writtenOpcodes, [0x14, 0x14], "the ring ended its run: start another")
        ring.advance(by: 120)
        XCTAssertEqual(ring.machine.phase, .measuring(.liveHeartRate), "a live session has no cap")

        ring.send(.stopLiveHeartRate)
        XCTAssertEqual(ring.written.last, F.packet("15"))
        XCTAssertEqual(ring.reports.last, .measurementFinished(.liveHeartRate))
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    func testASpotReadingTakesTheFirstPlausibleValueAndStops() {
        let ring = idleRing()
        let t0 = ring.now
        ring.send(.measure(.spotHeartRate))
        ring.notify(F.packet("1401020304 14"))  // 20 bpm: implausible
        ring.notify(F.hex("1410ef146a550000000000000000000000000000"))
        ring.notify(F.hex("14c0ec146a510000000000000000000000000000"))
        XCTAssertEqual(ring.writtenOpcodes, [0x14, 0x15])
        XCTAssertEqual(ring.reports, [.heartRate(bpm: 85, at: t0, during: .spotHeartRate),
                                      .measurementFinished(.spotHeartRate)])
    }

    func testASpotReadingStopsAtSixtySeconds() {
        let ring = idleRing()
        ring.send(.measure(.spotHeartRate))
        ring.advance(by: 30)
        ring.notify(F.packet("27"))
        XCTAssertEqual(ring.writtenOpcodes, [0x14, 0x14], "restarted, the cap still running")
        ring.advance(by: 29.9)
        XCTAssertEqual(ring.writtenOpcodes.last, 0x14)
        ring.advance(by: 0.2)
        XCTAssertEqual(ring.writtenOpcodes.last, 0x15)
        XCTAssertEqual(ring.reports, [.noReading(.spotHeartRate), .measurementFinished(.spotHeartRate)])
    }

    // MARK: - Oxygen

    func testOxygenWithAResult() {
        let ring = idleRing()
        let t0 = ring.now
        ring.send(.measure(.oxygen))
        XCTAssertEqual(ring.written, [F.packet("2301")])
        ring.advance(by: 10)
        ring.notify(F.packet("24"))
        ring.notify(F.packet("2401020332"))  // 50 %: implausible, still waiting
        ring.advance(by: 25)
        ring.notify(F.hex("245e774d63050000000000000000000000000000"))
        XCTAssertEqual(ring.written.last, F.packet("2300"))
        ring.notify(F.packet("28"))
        XCTAssertEqual(ring.reports, [.oxygen(percent: 99, at: t0.addingTimeInterval(10).addingTimeInterval(25)),
                                      .measurementFinished(.oxygen)])
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    func testOxygenWithProgressOnlyIsNoReading() {
        let ring = idleRing()
        ring.send(.measure(.oxygen))
        for _ in 0..<8 {
            ring.advance(by: 5)
            ring.notify(F.packet("24"))
        }
        ring.advance(by: 4.9)
        XCTAssertEqual(ring.writtenOpcodes, [0x23], "still waiting at 45 s less a moment")
        ring.advance(by: 0.2)
        XCTAssertEqual(ring.written.last, F.packet("2300"))
        XCTAssertEqual(ring.reports, [.noReading(.oxygen), .measurementFinished(.oxygen)])
    }

    // MARK: - One at a time

    func testAMeasurementDuringASyncWaitsForTheStepThenTheSyncResumes() {
        let ring = ring()
        ring.responses[0x10] = [F.sleepPacket(at: F.sleepLight0130, all: F.light)]
        ring.connect()
        ring.notify(F.activityExample)
        XCTAssertEqual(ring.machine.phase, .syncing(.sleep))
        ring.send(.measure(.oxygen))
        XCTAssertEqual(ring.writtenOpcodes.last, 0x10, "the sleep step finishes first")
        ring.advance(by: 2)
        XCTAssertEqual(ring.writtenOpcodes.last, 0x23)
        XCTAssertEqual(ring.machine.phase, .measuring(.oxygen))
        ring.notify(F.hex("24536c4261050000000000000000000000000000"))
        XCTAssertEqual(ring.writtenOpcodes.suffix(3), [0x23, 0x23, 0x16], "stop, then the sync resumes")
        ring.settle()
        XCTAssertTrue(ring.reports.contains(.oxygen(percent: 97, at: start.addingTimeInterval(2))))
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
    }

    func testASecondMeasurementIsRefusedWhileOneRuns() {
        let ring = idleRing()
        ring.send(.measure(.liveHeartRate))
        ring.send(.measure(.oxygen))
        XCTAssertEqual(ring.reports, [.measurementRefused(.oxygen)])
        XCTAssertEqual(ring.writtenOpcodes, [0x14])
    }

    func testAMeasurementWithoutALinkIsRefused() {
        let ring = ring()
        ring.send(.measure(.spotHeartRate))
        XCTAssertEqual(ring.reports, [.measurementRefused(.spotHeartRate)])
        XCTAssertTrue(ring.written.isEmpty)
    }

    func testAStartTheRingNeverAnswersIsNoReading() {
        let ring = idleRing()
        ring.silentOpcodes = [0x23]
        ring.send(.measure(.oxygen))
        ring.advance(by: 6)
        XCTAssertEqual(ring.reports.first, .noReading(.oxygen))
        XCTAssertEqual(ring.written.last, F.packet("2300"), "told to stop in case it started anyway")
        ring.settle()
        XCTAssertEqual(ring.reports.last, .measurementFinished(.oxygen))
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    // MARK: - Disconnects

    func testADisconnectMidSyncResetsAndTheNextConnectStartsAgain() {
        let ring = ring()
        ring.silentOpcodes = [0x21]
        ring.connect()
        XCTAssertEqual(ring.machine.phase, .syncing(.locale))
        ring.send(.disconnected)
        XCTAssertEqual(ring.machine.phase, .disconnected)
        XCTAssertEqual(ring.cancelledAll, 1)
        ring.advance(by: 30)
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21], "nothing written while disconnected")

        ring.silentOpcodes = []
        ring.clearRecords()
        ring.connect()
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes.first, 0x0c, "from the top")
        XCTAssertEqual(ring.reports.last, .syncFinished(at: ring.now))
    }

    func testAStaleTimerAfterADisconnectIsIgnored() throws {
        var machine = RingSyncMachine(configuration: .init(timeZone: minusFour))
        let effects = machine.handle(.linkReady, at: start)
        let ackTimer = effects.compactMap { effect -> RingTimer? in
            if case .startTimer(let timer, _) = effect { return timer }
            return nil
        }.first
        _ = machine.handle(.disconnected, at: start)
        _ = machine.handle(.linkReady, at: start)
        XCTAssertEqual(machine.handle(.timerFired(try XCTUnwrap(ackTimer)), at: start.addingTimeInterval(3)), [],
                       "the old connection's timer does nothing to the new one")
    }

    func testADisconnectDuringAMeasurementInterruptsIt() {
        let ring = idleRing()
        ring.send(.measure(.liveHeartRate))
        ring.send(.disconnected)
        XCTAssertEqual(ring.reports, [.measurementInterrupted(.liveHeartRate)])
        XCTAssertEqual(ring.machine.phase, .disconnected)
    }

    // MARK: - Anything, any time

    func testBatteryClenchAndUnknownPacketsAreReportedWhenever() {
        let ring = idleRing()
        ring.notify(F.hex("0b37000000000000000000000000000000000000"))
        ring.notify(F.hex("0602000000000000000000000000000000000000"))
        ring.notify(F.packet("20010203"))
        ring.notify([0x03, 0x01])
        XCTAssertEqual(ring.reports, [.battery(percent: 55), .clench, .unknownPacket(opcode: 0x20), .malformedPacket])
        XCTAssertTrue(ring.written.isEmpty)
    }
}

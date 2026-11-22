import XCTest
@testable import OpenGlasses

/// Plan MZ P2 — the ring service over a fake ring: the pairing record, a sync written to a fake
/// Health store, reconnecting, the note about the ring's own app, power posture, live heart rate,
/// measurements, the low-battery line and forgetting.
@MainActor
final class RingServiceTests: XCTestCase {

    private typealias F = RingFixture

    // MARK: - The pairing record

    func testThePairingRecordRoundTripsThroughPreferences() throws {
        let suite = "RingServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RingPairingStore(defaults: defaults)
        XCTAssertNil(store.load())

        var record = RingPairingRecord(pairingID: .make(), peripheralIdentifier: RingServiceRig.ringID,
                                       pairedAt: RingServiceRig.start)
        record.cursor.advance(.sleepAnalysis, to: RingServiceRig.start)
        record.latchedClock = RingClock(offsetSeconds: 19_800)
        record.lastSync = RingServiceRig.start.addingTimeInterval(60)
        store.save(record)
        XCTAssertEqual(store.load(), record)

        // Only the pairing's own fields: no reading has anywhere to go.
        let data = try XCTUnwrap(defaults.data(forKey: RingPairingStore.key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["pairingID", "peripheralIdentifier", "cursor", "latchedClock",
                                        "pairedAt", "lastSync"])

        store.clear()
        XCTAssertNil(store.load())
    }

    func testThePairingRecordIsRegisteredWithNoReadings() {
        let record = SensitiveStore.ringPairing.record
        XCTAssertEqual(record.owner, "RingPairingStore")
        XCTAssertEqual(record.ownerPaths, ["OpenGlasses/Sources/Services/Ring/RingPairing.swift"])
        XCTAssertEqual(record.deleteAll, .api("RingPairingStore.clear()"))
        XCTAssertNotEqual(record.dataClass, .clinical, "the record holds no health values")
        XCTAssertTrue(record.location.contains("ringPairingRecord"))
    }

    func testPairingMakesAFreshRecordAndConnects() {
        let rig = RingServiceRig()
        let ring = rig.service!
        ring.start()
        XCTAssertEqual(ring.link, .notPaired)
        XCTAssertTrue(rig.transport.connects.isEmpty, "nothing to connect to before pairing")

        ring.startScan()
        rig.transport.found(RingCandidate(id: RingServiceRig.ringID, displayName: "Smart ring", heldByAnotherApp: false))
        XCTAssertEqual(ring.candidates.map(\.id), [RingServiceRig.ringID])
        ring.pair(ring.candidates[0])

        let record = rig.pairingStore.record
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.peripheralIdentifier, RingServiceRig.ringID)
        XCTAssertNotEqual(record?.pairingID.rawValue, RingServiceRig.ringID.uuidString.lowercased(),
                          "the pairing id is never the Bluetooth identifier")
        XCTAssertEqual(rig.transport.connects, [RingServiceRig.ringID])
        XCTAssertEqual(ring.link, .connected)
        XCTAssertFalse(ring.scanning)
    }

    // MARK: - A sync, end to end

    func testASyncWritesSleepAndStepsToHealthAndMovesTheRecord() async {
        let rig = RingServiceRig(paired: true)
        let base = RingClock(offsetSeconds: 0).ringSeconds(for: RingServiceRig.start.addingTimeInterval(-8 * 3600))
        rig.transport.responses[0x10] = [
            F.sleepPacket(at: base, all: F.light),
            F.sleepPacket(at: base + 900, all: F.deep),
        ]
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        XCTAssertEqual(ring.link, .connected)
        XCTAssertTrue(ring.syncing)
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        await rig.drain()

        XCTAssertFalse(ring.syncing)
        XCTAssertEqual(ring.battery, 80)
        XCTAssertEqual(Array(rig.transport.writtenOpcodes.prefix(6)), [0x0c, 0x01, 0x21, 0x19, 0x07, 0x10],
                       "status, time, locale, schedule, the trigger (on by default), sleep")
        let kinds = Set(rig.health.all.map(\.kind))
        XCTAssertEqual(kinds, [.sleepAnalysis, .stepCount])
        let record = rig.pairingStore.record
        XCTAssertNotNil(record?.lastSync)
        XCTAssertEqual(record?.latchedClock, RingClock(offsetSeconds: 0))
        XCTAssertNotNil(record?.cursor.sleepAnalysis, "the cursor moved once Health took the batch")
        XCTAssertNotNil(record?.cursor.stepCount)
        XCTAssertTrue(ring.hasPeriodicSync, "the next sync is scheduled")
    }

    func testARefusedWriteLeavesTheCursorAndSaysWhy() async {
        let rig = RingServiceRig(paired: true)
        rig.health.refusal = .protectedDataUnavailable
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        await rig.drain()

        XCTAssertEqual(ring.lastWriteRefusal, .protectedDataUnavailable)
        XCTAssertNil(rig.pairingStore.record?.cursor.stepCount, "the ring is the buffer: the span is read again")
    }

    // MARK: - Reconnecting

    func testTheBackoffGrowsAndStopsGrowing() {
        XCTAssertEqual((0..<7).map(RingReconnectPolicy.delay(afterFailures:)), [2, 5, 15, 30, 60, 60, 60])
        XCTAssertEqual(RingReconnectPolicy.delay(afterFailures: -1), 2)
    }

    func testADropReconnectsAfterTheBackoffAndAReadyLinkResetsIt() {
        let rig = RingServiceRig(paired: true)
        let ring = rig.service!
        ring.start()
        XCTAssertEqual(rig.transport.connects.count, 1)

        rig.transport.connectsImmediately = false
        rig.transport.drop()
        XCTAssertEqual(ring.link, .connecting)
        XCTAssertEqual(ring.machinePhase, .disconnected)
        rig.scheduler.advance(by: 1.9)
        XCTAssertEqual(rig.transport.connects.count, 1, "not before the backoff")
        rig.scheduler.advance(by: 0.2)
        XCTAssertEqual(rig.transport.connects.count, 2)

        rig.transport.drop()
        rig.scheduler.advance(by: 4.9)
        XCTAssertEqual(rig.transport.connects.count, 2)
        rig.scheduler.advance(by: 0.2)
        XCTAssertEqual(rig.transport.connects.count, 3, "the second wait is longer")

        rig.transport.connectsImmediately = true
        rig.transport.drop()
        rig.scheduler.advance(by: 15)
        XCTAssertEqual(ring.link, .connected)
        XCTAssertEqual(ring.reconnectAttempts, 0, "a ready link starts the backoff again")
    }

    func testStoppingLetsGoAndDoesNotReconnect() {
        let rig = RingServiceRig(paired: true)
        let ring = rig.service!
        ring.start()
        ring.stop()
        XCTAssertEqual(ring.link, .stopped)
        XCTAssertEqual(rig.transport.disconnects, 1)
        rig.transport.drop()
        rig.scheduler.advance(by: 120)
        XCTAssertEqual(rig.transport.connects.count, 1)
        XCTAssertNotNil(rig.pairingStore.record, "stopping keeps the pairing")
    }

    func testBluetoothStateShowsInTheLink() {
        let rig = RingServiceRig(paired: true)
        rig.transport.connectsImmediately = false
        let ring = rig.service!
        ring.start()
        rig.transport.radio(.poweredOff)
        XCTAssertEqual(ring.link, .bluetoothOff)
        rig.transport.radio(.unauthorized)
        XCTAssertEqual(ring.link, .bluetoothDenied)
        rig.transport.connectsImmediately = true
        rig.transport.radio(.poweredOn)
        XCTAssertEqual(ring.link, .connected)
    }

    // MARK: - The ring's own app (decision 9)

    func testTheOtherAppNoticeIsShownOnceUntilTheRingIsForgotten() async {
        let rig = RingServiceRig()
        let ring = rig.service!
        ring.start()
        ring.startScan()
        let held = RingCandidate(id: RingServiceRig.ringID, displayName: "Smart ring", heldByAnotherApp: true)
        rig.transport.found(held)
        XCTAssertEqual(ring.otherAppNotice, RingOtherAppNotice.text)
        XCTAssertTrue(rig.noticeShown)

        ring.dismissOtherAppNotice()
        ring.stopScan()
        ring.startScan()
        rig.transport.found(held)
        XCTAssertNil(ring.otherAppNotice, "said once")

        let advertising = RingCandidate(id: UUID(), displayName: "Smart ring", heldByAnotherApp: false)
        XCTAssertFalse(RingOtherAppNotice.shouldShow(for: advertising, alreadyShown: false))

        rig.transport.responses[0x16] = [F.packet("16ff")]
        ring.pair(held)
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        await ring.forget()
        XCTAssertFalse(rig.noticeShown, "forgetting the ring lets the note be said again")
    }

    // MARK: - Power

    func testPowerPostureStretchesTheSyncAndHoldsBackUnaskedLiveSessions() {
        XCTAssertEqual(RingPowerPolicy.syncInterval(.normal), 1800)
        XCTAssertEqual(RingPowerPolicy.syncInterval(.conserve), 3600)
        XCTAssertEqual(RingPowerPolicy.syncInterval(.reserve), 3600)
        XCTAssertTrue(RingPowerPolicy.mayStartLiveSession(requestedNow: true, posture: .reserve))
        XCTAssertFalse(RingPowerPolicy.mayStartLiveSession(requestedNow: false, posture: .reserve))
        XCTAssertTrue(RingPowerPolicy.mayStartLiveSession(requestedNow: false, posture: .conserve))
    }

    func testAtConserveThePeriodicSyncWaitsTwiceAsLong() {
        let rig = RingServiceRig(paired: true)
        rig.posture = .conserve
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        XCTAssertTrue(ring.hasPeriodicSync)
        let periodic = rig.scheduler.pending.filter { $0.interval >= 1800 }
        XCTAssertEqual(periodic.map(\.interval), [3600])

        rig.transport.clearWritten()
        rig.scheduler.advance(by: 3600)
        XCTAssertEqual(rig.transport.writtenOpcodes.first, 0x0c, "the periodic sync ran")
    }

    func testAtReserveAWorkoutSessionIsNotRestartedAfterADrop() {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)

        rig.posture = .reserve
        rig.transport.clearWritten()
        ring.beginWorkoutHeartRate()
        XCTAssertEqual(rig.transport.writtenOpcodes, [0x14], "asked for now: starts even at reserve")

        rig.transport.drop()
        rig.transport.clearWritten()
        rig.scheduler.advance(by: 2)
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        XCTAssertFalse(rig.transport.writtenOpcodes.contains(0x14), "not restarted unasked at reserve")
        XCTAssertTrue(ring.workoutHeartRateWanted)

        rig.posture = .normal
        rig.transport.drop()
        rig.transport.clearWritten()
        // The reconnect (2 s), then the sync's current step finishes before the session restarts.
        rig.scheduler.advance(by: 2)
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        XCTAssertTrue(rig.transport.writtenOpcodes.contains(0x14), "restarted after the reconnect")
    }

    // MARK: - Live heart rate and measurements

    func testAWorkoutHoldsALiveSessionAndLetsItGo() async {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        rig.transport.clearWritten()

        ring.beginWorkoutHeartRate()
        XCTAssertEqual(ring.machinePhase, .measuring(.liveHeartRate))
        rig.transport.notify(F.packet("14 01020304 78"))
        XCTAssertEqual(ring.liveReadings.freshBeatsPerMinute, 120)
        XCTAssertEqual(ring.freshHeartRate, 120)
        let forWorkout = ring.workoutHeartRateSamples(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(forWorkout.map(\.value), [.heartRate(beatsPerMinute: 120)])

        ring.endWorkoutHeartRate()
        XCTAssertEqual(ring.workoutHeartRateSamples(from: .distantPast, to: .distantFuture), [], "let go with the session")
        XCTAssertEqual(rig.transport.writtenOpcodes, [0x14, 0x15])
        XCTAssertEqual(ring.machinePhase, .idle)
        await rig.drain()
        XCTAssertEqual(rig.health.all.filter { $0.kind == .heartRate }.count, 1, "the reading reached Health")
        XCTAssertEqual(rig.health.all.first { $0.kind == .heartRate }?.syncIdentifier,
                       forWorkout.first?.syncIdentifier, "the workout's copy replaces the standalone one")
    }

    func testASpotHeartRateAnswersWithItsReading() async {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        rig.transport.responses[0x14] = [F.packet("14 01020304 48")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)

        let outcome = await ring.measure(.spotHeartRate)
        XCTAssertEqual(outcome, .heartRate(72))
        XCTAssertEqual(ring.machinePhase, .idle, "stopped after the first reading")
    }

    func testAnOxygenRunWithoutAResultIsNoReading() async {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)

        let scheduler = rig.scheduler
        let pending = Task { @MainActor in await ring.measure(.oxygen) }
        await rig.drain()
        scheduler.advance(by: 46)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .noReading)
    }

    func testMeasuringNeedsAPairedConnectedRing() async {
        let unpaired = RingServiceRig()
        unpaired.service.start()
        let first = await unpaired.service.measure(.spotHeartRate)
        XCTAssertEqual(first, .notPaired)

        let away = RingServiceRig(paired: true)
        away.transport.connectsImmediately = false
        away.service.start()
        let second = await away.service.measure(.oxygen)
        XCTAssertEqual(second, .notConnected)
    }

    func testADropDuringAMeasurementInterruptsIt() async {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        rig.transport.connectsImmediately = true
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        rig.transport.connectsImmediately = false

        let pending = Task { @MainActor in await ring.measure(.oxygen) }
        await rig.drain()
        rig.transport.drop()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .interrupted)
    }

    // MARK: - Battery

    func testTheLowBatteryLineIsSaidOncePerCharge() {
        var notice = RingBatteryNotice()
        XCTAssertFalse(notice.shouldAnnounce(percent: 50))
        XCTAssertTrue(notice.shouldAnnounce(percent: 10))
        XCTAssertFalse(notice.shouldAnnounce(percent: 9))
        XCTAssertFalse(notice.shouldAnnounce(percent: 15), "not charged yet")
        XCTAssertFalse(notice.shouldAnnounce(percent: 8))
        XCTAssertFalse(notice.shouldAnnounce(percent: 60), "charged: armed again")
        XCTAssertTrue(notice.shouldAnnounce(percent: 7))
    }

    func testTheServiceSaysTheLowBatteryOnce() {
        let rig = RingServiceRig(paired: true)
        rig.transport.batteryLevel = 9
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.packet("0b08"))
        XCTAssertEqual(rig.announced, [RingBatteryNotice.line])
        XCTAssertEqual(ring.battery, 8)
    }

    // MARK: - Forget

    func testForgetLeavesTriggerModeThenClearsEverything() async {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        XCTAssertNotNil(ring.battery)
        rig.transport.clearWritten()

        await ring.forget()
        XCTAssertEqual(rig.transport.written, [RingFixture.packet("0700")], "trigger mode off before letting go")
        XCTAssertNil(rig.pairingStore.record)
        XCTAssertNil(ring.pairing)
        XCTAssertNil(ring.battery)
        XCTAssertNil(ring.lastSync)
        XCTAssertNil(ring.liveReadings.latest)
        XCTAssertEqual(ring.link, .notPaired)
        XCTAssertNil(ring.machinePhase)
        XCTAssertGreaterThanOrEqual(rig.transport.disconnects, 1)

        rig.transport.drop()
        rig.scheduler.advance(by: 120)
        XCTAssertEqual(rig.transport.connects.count, 1, "nothing to reconnect to")
    }

    func testForgetWithTheTriggerOffSendsNothing() async {
        var settings = RingService.Settings(heartRateSchedule: .recommended, trigger: .recommended, stepGoal: nil)
        settings.trigger.enabled = false
        let rig = RingServiceRig(settings: settings, paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        rig.service.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        XCTAssertFalse(rig.transport.writtenOpcodes.contains(0x07), "no trigger mode while the trigger is off")
        rig.transport.clearWritten()
        await rig.service.forget()
        XCTAssertTrue(rig.transport.written.isEmpty)
    }

    func testDeletingReadingsRemovesOnlyRingSamples() async throws {
        let rig = RingServiceRig()
        rig.health.others = [.init(fromThisApp: true, syncIdentifier: "ring.old.heartRate.1"),
                             .init(fromThisApp: true, syncIdentifier: nil),
                             .init(fromThisApp: false, syncIdentifier: "ring.other.heartRate.1")]
        let deleted = try await rig.service.deleteRingReadings()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(rig.health.others.count, 2)
    }

    // MARK: - Time zones and the packet log

    func testATimeZoneChangeSetsTheClockAgain() {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [F.packet("16ff")]
        let ring = rig.service!
        ring.start()
        rig.transport.notify(F.activityExample)
        rig.scheduler.advance(by: 30)
        rig.transport.clearWritten()
        ring.timeZoneDidChangeForTesting()
        XCTAssertEqual(rig.transport.writtenOpcodes, [0x01])
    }

    func testThePacketLogKeepsTwentyAndCountsUnknownOpcodes() {
        let rig = RingServiceRig(paired: true)
        let ring = rig.service!
        ring.start()
        for _ in 0..<3 { rig.transport.notify(F.packet("44")) }
        for _ in 0..<30 { rig.transport.notify(F.packet("f6")) }
        rig.transport.notify([0x01, 0x02])
        XCTAssertEqual(ring.packetLog.unknownOpcodes[0x44], 3)
        XCTAssertEqual(ring.packetLog.unknownOpcodes[0xf6], 30)
        XCTAssertEqual(ring.packetLog.malformedCount, 1)
        XCTAssertEqual(ring.packetLog.recent.count, RingPacketLog.capacity)
        XCTAssertEqual(ring.packetLog.recent.last?.hex, "01 02")
    }
}

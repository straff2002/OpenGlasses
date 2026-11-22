import XCTest
@testable import OpenGlasses

/// Plan MZ P4 — the ring as a trigger: single and double clenches, the debounce, suppression, a
/// photo action refusing a single clench, the trigger mode on and off on the ring, the defaults,
/// and the clench reaching the temple taps' performer.
@MainActor
final class RingTriggerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    private let talk = RingTriggerSetting.recommended
    private let photo = RingTriggerSetting(enabled: true, action: .photoDescribe)

    // MARK: - Single and double

    func testTwoClenchesWithinTheWindowAreADouble() {
        var classifier = RingClenchClassifier()
        XCTAssertEqual(classifier.classify(at: t0), .single)
        XCTAssertEqual(classifier.classify(at: t0.addingTimeInterval(1.1)), .double)
        XCTAssertEqual(classifier.classify(at: t0.addingTimeInterval(1.5)), .single, "a third starts again")
        XCTAssertEqual(classifier.classify(at: t0.addingTimeInterval(3.0)), .single, "too slow for a double")
        XCTAssertEqual(classifier.classify(at: t0.addingTimeInterval(3.5)), .double)
    }

    // MARK: - The engine

    func testASingleClenchStartsTalkingAndTheDebounceHoldsTheNext() {
        var engine = RingTriggerEngine()
        XCTAssertEqual(engine.handleClench(at: t0, setting: talk, activity: .standby), .fire(.startTalking))
        XCTAssertEqual(engine.handleClench(at: t0.addingTimeInterval(1.5), setting: talk, activity: .standby),
                       .ignored(.debounced))
        XCTAssertEqual(engine.handleClench(at: t0.addingTimeInterval(2.1), setting: talk, activity: .standby),
                       .fire(.startTalking))
    }

    func testAPhotoActionRefusesASingleClench() {
        var engine = RingTriggerEngine()
        XCTAssertEqual(engine.handleClench(at: t0, setting: photo, activity: .standby), .ignored(.awaitingDouble))
        XCTAssertEqual(engine.handleClench(at: t0.addingTimeInterval(0.6), setting: photo, activity: .standby),
                       .fire(.photoDescribe))
        XCTAssertEqual(engine.handleClench(at: t0.addingTimeInterval(5), setting: photo, activity: .standby),
                       .ignored(.awaitingDouble))
        XCTAssertEqual(engine.handleClench(at: t0.addingTimeInterval(7), setting: photo, activity: .standby),
                       .ignored(.awaitingDouble), "two seconds apart is two singles")
        XCTAssertTrue(RingTriggerSetting.needsDoubleClench(.photoToCameraRoll))
        XCTAssertTrue(RingTriggerSetting.needsDoubleClench(.toggleRecording))
        XCTAssertFalse(RingTriggerSetting.needsDoubleClench(.startTalking))
        XCTAssertFalse(RingTriggerSetting.needsDoubleClench(.quickAction("q")))
    }

    func testListeningSpeakingAndLiveSessionsSuppressIt() {
        for activity in [TempleContext.Activity.listening, .speaking, .liveSession] {
            var engine = RingTriggerEngine()
            XCTAssertEqual(engine.handleClench(at: t0, setting: talk, activity: activity), .ignored(.suppressed))
        }
        var engine = RingTriggerEngine()
        XCTAssertEqual(engine.handleClench(at: t0, setting: talk, activity: .thinking), .fire(.startTalking),
                       "the resolver, not the gate, turns this one down")
    }

    func testOffIgnoresEveryClench() {
        var engine = RingTriggerEngine()
        let off = RingTriggerSetting(enabled: false, action: .startTalking)
        XCTAssertEqual(engine.handleClench(at: t0, setting: off, activity: .standby), .ignored(.off))
    }

    // MARK: - Defaults (decision 8)

    func testTheTriggerIsOnByDefaultAndStartsTalking() {
        let keys = ["ringTriggerEnabled", "ringTriggerAction"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }

        XCTAssertEqual(Config.ringTriggerSetting, RingTriggerSetting(enabled: true, action: .startTalking))
        XCTAssertEqual(RingTriggerSetting.recommended, Config.ringTriggerSetting)

        Config.ringTriggerActionRaw = TempleAction.photoToCameraRoll.rawValue
        XCTAssertEqual(Config.ringTriggerSetting.action, .photoToCameraRoll)
        Config.ringTriggerActionRaw = "fromANewerBuild"
        XCTAssertEqual(Config.ringTriggerSetting.action, .nothing, "an unknown value is never another action")
    }

    func testTheAutomaticHeartRateDefaultsToEveryThirtyMinutes() {
        let saved = UserDefaults.standard.object(forKey: "ringHeartRateMinutes")
        defer { UserDefaults.standard.set(saved, forKey: "ringHeartRateMinutes") }
        UserDefaults.standard.removeObject(forKey: "ringHeartRateMinutes")
        XCTAssertEqual(Config.ringHeartRateSchedule, .every(minutes: 30))
        XCTAssertEqual(RingHeartRateSetting(minutes: 0).schedule, .off)
        XCTAssertEqual(RingHeartRateSetting(minutes: 10).schedule, .every(minutes: 10))
        XCTAssertEqual(RingHeartRateSetting(minutes: 17), .every30Minutes)
        XCTAssertEqual(RingHeartRateSetting.allCases.map(\.rawValue), [0, 30, 10])
    }

    // MARK: - Trigger mode on the ring

    private func machineRing(selfieMode: Bool) -> MockRingTransport {
        var configuration = RingSyncMachine.Configuration(timeZone: TimeZone(secondsFromGMT: 0)!)
        configuration.selfieMode = selfieMode
        let ring = MockRingTransport(configuration: configuration, now: t0)
        ring.responses[0x16] = [RingFixture.packet("16ff")]
        return ring
    }

    func testTriggerModeIsTurnedOnAtEveryConnectWhileTheTriggerIsOn() {
        let ring = machineRing(selfieMode: true)
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes, [0x0c, 0x01, 0x21, 0x19, 0x07, 0x10, 0x16])
        XCTAssertTrue(ring.written.contains(RingFixture.packet("0701")))

        ring.send(.disconnected)
        ring.clearRecords()
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        XCTAssertTrue(ring.written.contains(RingFixture.packet("0701")), "re-enabled after a reconnect")
    }

    func testNoTriggerModeWhileTheTriggerIsOff() {
        let ring = machineRing(selfieMode: false)
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        XCTAssertFalse(ring.writtenOpcodes.contains(0x07))
    }

    func testTurningTheTriggerOffWhileLinkedSendsTheOffCommandOnce() {
        let ring = machineRing(selfieMode: true)
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        ring.clearRecords()

        ring.send(.setSelfieMode(false))
        XCTAssertEqual(ring.written, [RingFixture.packet("0700")])
        XCTAssertEqual(ring.reports, [.commandFinished(.selfieModeOff)])
        XCTAssertFalse(ring.machine.configuration.selfieMode)

        ring.send(.disconnected)
        ring.clearRecords()
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        XCTAssertFalse(ring.writtenOpcodes.contains(0x07), "off stays off at the next connect")

        ring.clearRecords()
        ring.send(.setSelfieMode(true))
        XCTAssertEqual(ring.written, [RingFixture.packet("0701")])
    }

    func testAnUnansweredTriggerCommandIsRetriedThenReported() {
        let ring = machineRing(selfieMode: false)
        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        ring.clearRecords()
        ring.silentOpcodes = [0x07]
        ring.send(.setSelfieMode(true))
        ring.settle()
        XCTAssertEqual(ring.writtenOpcodes, [0x07, 0x07], "one retry")
        XCTAssertEqual(ring.reports, [.commandFailed(.selfieModeOn)])
        XCTAssertEqual(ring.machine.phase, .idle)
    }

    func testFindRingAndScheduleChangesAreSent() {
        let ring = machineRing(selfieMode: false)
        ring.send(.findRing)
        XCTAssertEqual(ring.reports, [.commandFailed(.findRing)], "not linked")
        ring.clearRecords()

        ring.connect(burst: [RingFixture.activityExample])
        ring.settle()
        ring.clearRecords()
        ring.send(.findRing)
        XCTAssertEqual(ring.written, [RingFixture.packet("040a")])
        XCTAssertEqual(ring.reports, [.commandFinished(.findRing)])

        ring.clearRecords()
        ring.send(.setHeartRateSchedule(.every(minutes: 10)))
        XCTAssertEqual(ring.written, [RingFixture.packet("19 0000173b 01 0a 02")])
    }

    func testACommandDuringASyncWaitsForTheCurrentStep() {
        let ring = machineRing(selfieMode: false)
        ring.silentOpcodes = [0x0c]
        ring.connect()
        XCTAssertEqual(ring.machine.phase, .syncing(.status))
        ring.send(.findRing)
        XCTAssertEqual(ring.writtenOpcodes, [0x0c])
        ring.silentOpcodes = []
        ring.notify(RingFixture.packet("0c"))
        XCTAssertEqual(Array(ring.writtenOpcodes.prefix(3)), [0x0c, 0x04, 0x01], "then the sync carries on")
    }

    // MARK: - Reaching the performer

    private final class FakeApp: TempleActionPerforming {
        var context = TempleContext(activity: .standby, glassesCameraReady: false)
        var effects: [TempleEffect] = []
        var earcons: [TempleEarcon] = []
        var lines: [String] = []
        func templeContext() -> TempleContext { context }
        func performTempleEffect(_ effect: TempleEffect) async { effects.append(effect) }
        func playTempleEarcon(_ earcon: TempleEarcon) { earcons.append(earcon) }
        func announceTempleLine(_ line: String) async { lines.append(line) }
    }

    func testAClenchIsCarriedOutAsATempleTapWouldBe() async {
        let app = FakeApp()
        let outcome = await RingTriggerRunner.run(.startTalking, performer: app)
        XCTAssertEqual(outcome, .carriedOut(.run(.startListening)))
        XCTAssertEqual(app.effects, [.startListening])
        XCTAssertEqual(app.earcons, [TempleEarcon.for(.run(.startListening))], "the temple tap's earcon")

        let photo = await RingTriggerRunner.run(.photoDescribe, performer: app)
        XCTAssertEqual(photo, .carriedOut(.ignored(.noGlassesCamera)))
        XCTAssertEqual(app.earcons.last, .refused)
        XCTAssertEqual(app.lines, [TempleIgnoreReason.noGlassesCamera.spokenLine!])
    }

    func testTheServiceHandsAClenchToTheTrigger() {
        let rig = RingServiceRig(paired: true)
        rig.service.start()
        rig.transport.notify(RingFixture.packet("0602"))
        XCTAssertEqual(rig.triggered, [.startTalking])

        rig.scheduler.advance(by: 3)
        rig.activity = .listening
        rig.transport.notify(RingFixture.packet("0602"))
        XCTAssertEqual(rig.triggered, [.startTalking], "suppressed while listening")

        rig.activity = .standby
        rig.scheduler.advance(by: 3)
        rig.settings.trigger.enabled = false
        rig.transport.notify(RingFixture.packet("0602"))
        XCTAssertEqual(rig.triggered, [.startTalking], "off")
    }

    func testTurningTheTriggerOffInTheServiceSendsTheOffCommand() {
        let rig = RingServiceRig(paired: true)
        rig.transport.responses[0x16] = [RingFixture.packet("16ff")]
        rig.service.start()
        rig.transport.notify(RingFixture.activityExample)
        rig.scheduler.advance(by: 30)
        rig.transport.clearWritten()
        rig.service.triggerEnabledChanged(false)
        XCTAssertEqual(rig.transport.written, [RingFixture.packet("0700")])
    }
}

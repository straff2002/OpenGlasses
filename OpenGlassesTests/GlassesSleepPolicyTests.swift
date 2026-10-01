import XCTest
@testable import OpenGlasses

/// When the app stands down from glasses on its own, when it comes back, and the guard that keeps
/// the glasses' arrival from reconfiguring audio under a turn in progress.
final class GlassesSleepPolicyTests: XCTestCase {

    private let on = true   // holdsGlassesMic

    // MARK: - Mode: what is held open

    func testAlwaysOnListeningIsListeningOnAndNotPushToTalk() {
        XCTAssertTrue(GlassesSleepPolicy.alwaysOnListening(listeningEnabled: true, silentMode: false))
        XCTAssertFalse(GlassesSleepPolicy.alwaysOnListening(listeningEnabled: true, silentMode: true))
        XCTAssertFalse(GlassesSleepPolicy.alwaysOnListening(listeningEnabled: false, silentMode: false))
        XCTAssertFalse(GlassesSleepPolicy.alwaysOnListening(listeningEnabled: false, silentMode: true))
    }

    func testWithNoAlwaysOnListenerNothingEverSleeps() {
        for worn: Bool? in [true, false, nil] {
            for option in [true, false] {
                XCTAssertFalse(GlassesSleepPolicy.shouldArmSilenceSleep(
                    holdsGlassesMic: false, autoSleepMinutes: 5, worn: worn,
                    sleepWhenQuietWhileWorn: option))
                XCTAssertFalse(GlassesSleepPolicy.silenceSleepFires(
                    holdsGlassesMic: false, idle: true, inUse: true, worn: worn,
                    sleepWhenQuietWhileWorn: option))
            }
            XCTAssertFalse(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: false,
                                                               worn: worn, inUse: true),
                           "nothing held open: taking them off does not stand down")
        }
    }

    // MARK: - Idle listening on the phone (Plan GU, Greig's answer 2)

    func testTheListenerHoldsTheGlassesMicOnlyWhenItWaitsOnThem() {
        XCTAssertTrue(GlassesSleepPolicy.holdsGlassesMic(alwaysOnListening: true, idleListensOnGlasses: true))
        XCTAssertFalse(GlassesSleepPolicy.holdsGlassesMic(alwaysOnListening: true, idleListensOnGlasses: false),
                       "listening on the iPhone holds nothing on the glasses")
        XCTAssertFalse(GlassesSleepPolicy.holdsGlassesMic(alwaysOnListening: false, idleListensOnGlasses: true))
    }

    /// Taken off with the link up, idle listening on the iPhone: the wake word keeps listening on
    /// the phone — no doff stand-down, no silence countdown.
    func testDoffingWithIdleListeningOnThePhoneNeverStandsDown() {
        let plan = WakeListenPolicy.decide(.init(listeningEnabled: true, silentMode: false,
                                                 wakeListenMic: .iPhone, micRoute: .glasses))
        let holds = GlassesSleepPolicy.holdsGlassesMic(alwaysOnListening: true,
                                                       idleListensOnGlasses: plan.holdsGlassesMic)
        XCTAssertFalse(holds)
        XCTAssertFalse(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: holds, worn: false, inUse: true))
        XCTAssertFalse(GlassesSleepPolicy.shouldArmSilenceSleep(
            holdsGlassesMic: holds, autoSleepMinutes: 5, worn: nil, sleepWhenQuietWhileWorn: true))
        XCTAssertTrue(GlassesUse().voiceInputAvailable, "voice input stays open")
    }

    /// "Same as Microphone" with the glasses as the Microphone keeps today's rules.
    func testIdleListeningOnTheGlassesKeepsTheDoffStandDown() {
        let plan = WakeListenPolicy.decide(.init(listeningEnabled: true, silentMode: false,
                                                 wakeListenMic: .sameAsMicrophone, micRoute: .glasses))
        let holds = GlassesSleepPolicy.holdsGlassesMic(alwaysOnListening: true,
                                                       idleListensOnGlasses: plan.holdsGlassesMic)
        XCTAssertTrue(holds)
        XCTAssertTrue(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: holds, worn: false, inUse: true))
    }

    /// The wearer's own Disconnect still closes voice input whatever the idle mic.
    func testTheWearersDisconnectStillClosesVoiceInput() {
        var use = connectedUse()
        use.standDown(.user)
        XCTAssertFalse(use.voiceInputAvailable)
        let plan = WakeListenPolicy.decide(.init(listeningEnabled: true, silentMode: false,
                                                 voiceInputAvailable: use.voiceInputAvailable,
                                                 wakeListenMic: .iPhone, micRoute: .glasses))
        XCTAssertEqual(plan.listen, .off, "stood down: no idle session at all")
    }

    // MARK: - Taken off

    func testTakenOffWithTheLinkUpStartsTheGrace() {
        XCTAssertTrue(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: on, worn: false, inUse: true))
        XCTAssertEqual(GlassesSleepPolicy.doffGraceSeconds, 30)
    }

    func testPutBackOnWithinTheGraceCancelsIt() {
        // The grace is re-checked at its end; worn again means it does not fire.
        XCTAssertFalse(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: on, worn: true, inUse: true))
        XCTAssertFalse(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: on, worn: nil, inUse: true))
    }

    func testNoGraceForGlassesNotInUse() {
        XCTAssertFalse(GlassesSleepPolicy.doffGraceApplies(holdsGlassesMic: on, worn: false, inUse: false),
                       "already stood down, or the link is gone: nothing to time")
    }

    // MARK: - Silence

    func testWornNeverSleepsForSilenceByDefault() {
        XCTAssertFalse(GlassesSleepPolicy.shouldArmSilenceSleep(
            holdsGlassesMic: on, autoSleepMinutes: 5, worn: true, sleepWhenQuietWhileWorn: false))
        XCTAssertFalse(GlassesSleepPolicy.silenceSleepFires(
            holdsGlassesMic: on, idle: true, inUse: true, worn: true, sleepWhenQuietWhileWorn: false))
    }

    func testTheOptionLetsWornGlassesSleepForSilence() {
        XCTAssertTrue(GlassesSleepPolicy.shouldArmSilenceSleep(
            holdsGlassesMic: on, autoSleepMinutes: 5, worn: true, sleepWhenQuietWhileWorn: true))
        XCTAssertTrue(GlassesSleepPolicy.silenceSleepFires(
            holdsGlassesMic: on, idle: true, inUse: true, worn: true, sleepWhenQuietWhileWorn: true))
    }

    func testUnknownWornStateFallsBackToTheSilenceRule() {
        for option in [true, false] {
            XCTAssertTrue(GlassesSleepPolicy.shouldArmSilenceSleep(
                holdsGlassesMic: on, autoSleepMinutes: 5, worn: nil, sleepWhenQuietWhileWorn: option))
            XCTAssertTrue(GlassesSleepPolicy.silenceSleepFires(
                holdsGlassesMic: on, idle: true, inUse: true, worn: nil, sleepWhenQuietWhileWorn: option))
        }
    }

    func testPuttingThemOnDuringTheSilenceCountdownStopsIt() {
        XCTAssertTrue(GlassesSleepPolicy.shouldArmSilenceSleep(
            holdsGlassesMic: on, autoSleepMinutes: 5, worn: nil, sleepWhenQuietWhileWorn: false))
        XCTAssertFalse(GlassesSleepPolicy.silenceSleepFires(
            holdsGlassesMic: on, idle: true, inUse: true, worn: true, sleepWhenQuietWhileWorn: false))
    }

    func testSilenceFiresOnlyForIdleGlassesStillInUse() {
        XCTAssertFalse(GlassesSleepPolicy.silenceSleepFires(
            holdsGlassesMic: on, idle: false, inUse: true, worn: nil, sleepWhenQuietWhileWorn: false))
        XCTAssertFalse(GlassesSleepPolicy.silenceSleepFires(
            holdsGlassesMic: on, idle: true, inUse: false, worn: nil, sleepWhenQuietWhileWorn: false))
    }

    func testZeroMinutesNeverArms() {
        XCTAssertFalse(GlassesSleepPolicy.shouldArmSilenceSleep(
            holdsGlassesMic: on, autoSleepMinutes: 0, worn: nil, sleepWhenQuietWhileWorn: true))
    }

    func testTheOptionDefaultsOff() {
        let key = "sleepWhenQuietWhileWorn"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.sleepWhenQuietWhileWorn)
    }

    // MARK: - Who lifts a stand-down

    private func connectedUse() -> GlassesUse {
        var use = GlassesUse()
        use.linkChanged(.connected)
        return use
    }

    func testPuttingThemBackOnResumesAnAutomaticStandDown() {
        var use = connectedUse()
        use.standDown(.automatic)
        XCTAssertFalse(use.inUse)
        use.donned()
        XCTAssertTrue(use.inUse, "back on the face: no tap needed")
    }

    func testPuttingThemOnNeverUndoesTheWearersDisconnect() {
        var use = connectedUse()
        use.standDown(.user)
        use.donned()
        XCTAssertFalse(use.inUse)
        XCTAssertEqual(use.standDownReason, .user)
        use.resume()
        XCTAssertTrue(use.inUse, "only an explicit connect lifts it")
    }

    func testTheWearersDisconnectOutranksAnAutomaticStandDown() {
        var use = connectedUse()
        use.standDown(.automatic)
        use.standDown(.user)
        XCTAssertEqual(use.standDownReason, .user)
        use.donned()
        XCTAssertFalse(use.inUse)

        var other = connectedUse()
        other.standDown(.user)
        other.standDown(.automatic)
        XCTAssertEqual(other.standDownReason, .user, "an automatic one never downgrades it")
    }

    func testTheLinkComingBackLiftsEitherKind() {
        for reason: GlassesUse.StandDownReason in [.user, .automatic] {
            var use = connectedUse()
            use.standDown(reason)
            use.linkChanged(.addedDisconnected)
            use.linkChanged(.connected)
            XCTAssertTrue(use.inUse, "\(reason)")
        }
    }

    // MARK: - Worn from the SDK, through the snapshot and the service

    func testWornIsReportedOnlyWhileConnected() {
        var s = GlassesConnectionSnapshot(registration: .registered)
        s.apply(.devices(["a"]))
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: true)))
        XCTAssertEqual(s.liveWorn, true)
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: false)))
        XCTAssertEqual(s.liveWorn, false)
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: nil)))
        XCTAssertNil(s.liveWorn, "the device does not say")
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .disconnected, worn: true)))
        XCTAssertNil(s.liveWorn, "away is not worn by anything the app can see")
    }

    // MARK: - Glasses audio hand-off

    func testTheHandOffRunsOnlyIntoAnIdleApp() {
        XCTAssertTrue(GlassesAudioHandoffPolicy.mayHandOff(inConversation: false, isListening: false,
                                                           isProcessing: false, isSpeaking: false))
        // The device trace: "Resume & Talk" brought the glasses back and started dictation; the
        // hand-off 2.5 s later reconfigured the session under it.
        XCTAssertFalse(GlassesAudioHandoffPolicy.mayHandOff(inConversation: true, isListening: true,
                                                            isProcessing: false, isSpeaking: false))
        XCTAssertFalse(GlassesAudioHandoffPolicy.mayHandOff(inConversation: true, isListening: false,
                                                            isProcessing: false, isSpeaking: false))
        XCTAssertFalse(GlassesAudioHandoffPolicy.mayHandOff(inConversation: false, isListening: true,
                                                            isProcessing: false, isSpeaking: false))
        XCTAssertFalse(GlassesAudioHandoffPolicy.mayHandOff(inConversation: false, isListening: false,
                                                            isProcessing: true, isSpeaking: false))
        XCTAssertFalse(GlassesAudioHandoffPolicy.mayHandOff(inConversation: false, isListening: false,
                                                            isProcessing: false, isSpeaking: true))
    }
}

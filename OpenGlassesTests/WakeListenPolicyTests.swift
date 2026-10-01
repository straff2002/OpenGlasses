import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan GU §1 — where the idle wake-word listener waits, row by row of the plan's table.
@MainActor
final class WakeListenPolicyTests: XCTestCase {

    private func inputs(listening: Bool = true, silent: Bool = false, muted: Bool = false,
                        voice: Bool = true, carPlay: Bool = false, foreign: Bool = false,
                        consumer: Bool = false, wakeMic: WakeListenMic = .iPhone,
                        route: MicRoute = .glasses, posture: PowerPosture = .normal,
                        gate: Bool = false) -> WakeListenPolicy.Inputs {
        WakeListenPolicy.Inputs(listeningEnabled: listening, silentMode: silent, micMuted: muted,
                                voiceInputAvailable: voice, carPlayMode: carPlay,
                                foreignOwner: foreign, wearerAudioConsumerActive: consumer,
                                wakeListenMic: wakeMic, micRoute: route, posture: posture,
                                speechGateEnabled: gate)
    }

    // MARK: - Rows

    func testNobodyWantingAListenerHoldsNoSession() {
        for i in [inputs(listening: false), inputs(silent: true), inputs(muted: true), inputs(voice: false)] {
            let plan = WakeListenPolicy.decide(i)
            XCTAssertEqual(plan.listen, .off)
            XCTAssertFalse(plan.holdsSession, "listening off, push-to-talk, muted or stood down: no session")
            XCTAssertFalse(plan.speechGate)
        }
    }

    func testOffOutranksEveryOtherRow() {
        let plan = WakeListenPolicy.decide(inputs(silent: true, carPlay: true, foreign: true, consumer: true,
                                                  wakeMic: .sameAsMicrophone))
        XCTAssertEqual(plan.listen, .off)
    }

    func testAForeignOwnersSessionIsNotOurs() {
        let plan = WakeListenPolicy.decide(inputs(carPlay: true, foreign: true))
        XCTAssertEqual(plan.listen, .notOurs)
        XCTAssertFalse(plan.holdsSession)
    }

    func testCarPlayIsUnchanged() {
        let plan = WakeListenPolicy.decide(inputs(carPlay: true, wakeMic: .iPhone))
        XCTAssertEqual(plan.listen, .carPlay)
        XCTAssertEqual(plan.mode, .voiceChat)
        XCTAssertEqual(plan.categoryOptions,
                       [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        XCTAssertNil(plan.preferredInput, "the car decides")
        XCTAssertFalse(WakeListenPolicy.decide(inputs(carPlay: true, gate: true)).speechGate)
    }

    func testAWearerAudioConsumerKeepsTheBluetoothConversationMic() {
        for route in [MicRoute.glasses, .headset] {
            let plan = WakeListenPolicy.decide(inputs(consumer: true, wakeMic: .iPhone, route: route))
            XCTAssertEqual(plan.listen, .bluetooth(route))
            XCTAssertEqual(plan.categoryOptions, MicRoutePolicy.categoryOptions(for: route, mixWithOthers: true),
                           "today's hold, released when the consumer stops")
        }
        // A phone conversation mic has nothing to hold.
        XCTAssertEqual(WakeListenPolicy.decide(inputs(consumer: true, route: .phone)).listen, .phone)
    }

    func testTheConsumerHoldOutranksThePowerOverride() {
        let plan = WakeListenPolicy.decide(inputs(consumer: true, wakeMic: .sameAsMicrophone, posture: .reserve))
        XCTAssertEqual(plan.listen, .bluetooth(.glasses), "a recording does not change mic because the battery dipped")
    }

    func testSameAsMicrophoneIsTodaysHoldByChoice() {
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, route: .glasses)).listen,
                       .bluetooth(.glasses))
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, route: .headset)).listen,
                       .bluetooth(.headset))
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, route: .phone)).listen,
                       .phone)
    }

    func testTheDefaultIsThePhoneMicWithA2DPOutput() {
        for route in MicRoute.allCases {
            let plan = WakeListenPolicy.decide(inputs(route: route))
            XCTAssertEqual(plan.listen, .phone)
            XCTAssertEqual(plan.mode, .default)
            XCTAssertEqual(plan.categoryOptions, [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            XCTAssertFalse(plan.categoryOptions.contains(.allowBluetoothHFP), "never the call link while idle")
            XCTAssertEqual(plan.preferredInput, .phone)
        }
    }

    // MARK: - Power posture

    func testReserveOverridesAGlassesIdleChoiceToThePhone() {
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, posture: .reserve)).listen, .phone)
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, posture: .conserve)).listen,
                       .bluetooth(.glasses), "only reserve")
        XCTAssertEqual(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, route: .headset,
                                                      posture: .reserve)).listen,
                       .bluetooth(.headset), "a headset is not the glasses' radio")
    }

    func testPostureFlags() {
        XCTAssertFalse(PowerPosture.normal.prefersStrictWakeGate)
        XCTAssertTrue(PowerPosture.conserve.prefersStrictWakeGate)
        XCTAssertTrue(PowerPosture.reserve.prefersStrictWakeGate)
        XCTAssertFalse(PowerPosture.normal.prefersPhoneWakeMic)
        XCTAssertFalse(PowerPosture.conserve.prefersPhoneWakeMic)
        XCTAssertTrue(PowerPosture.reserve.prefersPhoneWakeMic)
    }

    func testTheGateFollowsTheFlagAndPostureMakesItStrict() {
        XCTAssertFalse(WakeListenPolicy.decide(inputs()).speechGate, "off by default")
        let gated = WakeListenPolicy.decide(inputs(gate: true))
        XCTAssertTrue(gated.speechGate)
        XCTAssertFalse(gated.strictGate)
        XCTAssertTrue(WakeListenPolicy.decide(inputs(posture: .conserve, gate: true)).strictGate)
        XCTAssertTrue(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, gate: true)).speechGate)
    }

    // MARK: - Glasses idle

    func testSilenceMeansGlassesIdleOnlyOnTheGlassesMic() {
        XCTAssertFalse(WakeListenPolicy.decide(inputs()).silenceMeansGlassesIdle,
                       "silence on the phone's mic is a quiet room")
        XCTAssertTrue(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone)).silenceMeansGlassesIdle)
        XCTAssertFalse(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone, route: .headset))
            .silenceMeansGlassesIdle)
        XCTAssertTrue(WakeListenPolicy.decide(inputs(wakeMic: .sameAsMicrophone)).holdsGlassesMic)
        XCTAssertFalse(WakeListenPolicy.decide(inputs()).holdsGlassesMic)
    }

    func testWearerAudioConsumersAreTheVoiceCapturersNotTheRoomCapturers() {
        XCTAssertTrue(WakeListenPolicy.wearerAudioConsumerIDs.contains("ambient_captions"))
        XCTAssertTrue(WakeListenPolicy.wearerAudioConsumerIDs.contains("teleprompter"))
        XCTAssertTrue(WakeListenPolicy.wearerAudioConsumerIDs.contains("capture_audio_router"))
        XCTAssertFalse(WakeListenPolicy.wearerAudioConsumerIDs.contains("memory_rewind"))
        XCTAssertFalse(WakeListenPolicy.wearerAudioConsumerIDs.contains("audio_recording"))
        XCTAssertFalse(WakeListenPolicy.wearerAudioConsumerIDs.contains("default"), "dictation is the turn's")
        XCTAssertEqual(CaptureAudioRouter.sourceConsumerId, "capture_audio_router")
        XCTAssertEqual(TeleprompterService.recognitionConsumerID, "teleprompter")
    }

    // MARK: - Settings

    func testTheWakeMicSettingDefaultsToTheIPhone() {
        let key = "wakeListenMic"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Config.wakeListenMic, .iPhone)
        Config.setWakeListenMic(.sameAsMicrophone)
        XCTAssertEqual(Config.wakeListenMic, .sameAsMicrophone)
    }

    func testTheSpeechGateDefaultsOff() {
        let key = "wakeSpeechGateEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(Config.wakeSpeechGateEnabled)
    }
}

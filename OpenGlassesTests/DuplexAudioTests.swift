import XCTest
@testable import OpenGlasses

/// Plan CC P1 — the duplex-audio pure core: dead-IO detection and the echo-suppression truth table.
final class DuplexAudioTests: XCTestCase {

    // MARK: - VoiceProcessingProbe

    /// A zero sample rate is THE dead-IO signature — the exact condition that silenced capture
    /// entirely when voice processing was enabled on a long-lived engine. Detecting it is what
    /// turns "deaf always" into "fall back to half-duplex".
    func testZeroSampleRateIsDeadIO() {
        guard case .deadIO(let reason) = VoiceProcessingProbe.verdict(sampleRate: 0, channelCount: 1) else {
            return XCTFail("0 Hz must read as dead IO")
        }
        XCTAssertTrue(reason.contains("dead-IO"), "the reason names the signature for the field log")
    }

    func testZeroChannelsIsDeadIO() {
        guard case .deadIO = VoiceProcessingProbe.verdict(sampleRate: 48_000, channelCount: 0) else {
            return XCTFail("zero channels must read as dead IO")
        }
    }

    func testHealthyFormatsAreUsable() {
        // The rates hardware actually reports: 48 kHz native, 24/16 kHz after VP, mono and stereo.
        for (rate, channels) in [(48_000.0, UInt32(1)), (44_100, 2), (24_000, 1), (16_000, 1)] {
            XCTAssertEqual(VoiceProcessingProbe.verdict(sampleRate: rate, channelCount: channels),
                           .usable, "\(rate) Hz / \(channels)ch")
        }
    }

    func testNegativeSampleRateIsDeadIONotUsable() {
        guard case .deadIO = VoiceProcessingProbe.verdict(sampleRate: -1, channelCount: 1) else {
            return XCTFail("a nonsense negative rate must not read as usable")
        }
    }

    // MARK: - EchoSuppressionPolicy: the full truth table

    /// All eight combinations, exhaustively — the gate used to be an inline condition duplicated in
    /// two session managers, and a table is how the two stop drifting.
    func testTruthTable() {
        struct Case {
            let capability: DuplexAudioCapability
            let iPhone: Bool
            let speaking: Bool
            let drop: Bool
            let why: String
        }
        let cases: [Case] = [
            // Glasses mode: mic is remote, no co-located speaker — never drop, whatever the tier.
            .init(capability: .halfDuplex, iPhone: false, speaking: true, drop: false,
                  why: "glasses mic must stay open even while the model speaks"),
            .init(capability: .halfDuplex, iPhone: false, speaking: false, drop: false,
                  why: "glasses, idle"),
            .init(capability: .echoCancelled, iPhone: false, speaking: true, drop: false,
                  why: "glasses, echo-cancelled tier is irrelevant"),
            .init(capability: .echoCancelled, iPhone: false, speaking: false, drop: false,
                  why: "glasses, idle"),
            // iPhone + echo-cancelled: the whole point — open mic during model speech = barge-in.
            .init(capability: .echoCancelled, iPhone: true, speaking: true, drop: false,
                  why: "echo-cancelled iPhone mic stays open while the model speaks"),
            .init(capability: .echoCancelled, iPhone: true, speaking: false, drop: false,
                  why: "echo-cancelled, idle"),
            // iPhone + half-duplex: the surviving legitimate mute, and ONLY while speaking.
            .init(capability: .halfDuplex, iPhone: true, speaking: true, drop: true,
                  why: "half-duplex fallback drops during model speech (the old behaviour)"),
            .init(capability: .halfDuplex, iPhone: true, speaking: false, drop: false,
                  why: "half-duplex but the model is silent — the user must be heard"),
        ]
        for c in cases {
            XCTAssertEqual(
                EchoSuppressionPolicy.shouldDropCapturedBuffer(
                    capability: c.capability, iPhoneMode: c.iPhone, modelSpeaking: c.speaking),
                c.drop, c.why)
        }
    }

    /// The one row that IS the shipped defect, pinned on its own: half-duplex iPhone mode drops
    /// during speech (so the fallback tier keeps today's echo protection), while the
    /// echo-cancelled tier does not (so barge-in exists at all).
    func testBargeInIsExactlyWhatTheEchoCancelledTierBuys() {
        XCTAssertTrue(EchoSuppressionPolicy.shouldDropCapturedBuffer(
            capability: .halfDuplex, iPhoneMode: true, modelSpeaking: true))
        XCTAssertFalse(EchoSuppressionPolicy.shouldDropCapturedBuffer(
            capability: .echoCancelled, iPhoneMode: true, modelSpeaking: true))
    }

    // MARK: - Flag default

    func testDuplexAudioDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "duplexAudioEnabled")
        XCTAssertFalse(Config.duplexAudioEnabled,
                       "default off until the device matrix passes — the risked failure (deaf always) is worse than the mute")
        Config.setDuplexAudioEnabled(true)
        XCTAssertTrue(Config.duplexAudioEnabled)
        UserDefaults.standard.removeObject(forKey: "duplexAudioEnabled")
    }
}

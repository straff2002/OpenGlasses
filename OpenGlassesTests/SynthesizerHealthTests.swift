import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan GB P4 — the wedged system synthesizer: the pure health verdict, the rebuild-and-retry with
/// a synthesizer that never calls back, the media-services reset, and the held utterance that is
/// replayed rather than dropped.
@MainActor
final class SynthesizerHealthTests: XCTestCase {

    // MARK: - Policy

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testNeverStartedAfterTheStartTimeout() {
        XCTAssertEqual(SynthesizerHealthPolicy.assess(speakAt: t0, didStartAt: nil, lastBoundaryAt: nil,
                                                      characters: 40, rate: AVSpeechUtteranceDefaultSpeechRate,
                                                      now: t0.addingTimeInterval(3)), .healthy)
        XCTAssertEqual(SynthesizerHealthPolicy.assess(speakAt: t0, didStartAt: nil, lastBoundaryAt: nil,
                                                      characters: 40, rate: AVSpeechUtteranceDefaultSpeechRate,
                                                      now: t0.addingTimeInterval(4.5)), .neverStarted)
    }

    func testStalledOnlyWhenOverrunAndQuiet() {
        let rate = AVSpeechUtteranceDefaultSpeechRate
        let chars = 140   // ≈ 10 s at the default rate, + 5 s slack
        let started = t0.addingTimeInterval(0.2)
        // Long past its length but a word boundary just now: still talking.
        XCTAssertEqual(SynthesizerHealthPolicy.assess(speakAt: t0, didStartAt: started,
                                                      lastBoundaryAt: t0.addingTimeInterval(19),
                                                      characters: chars, rate: rate,
                                                      now: t0.addingTimeInterval(20)), .healthy)
        // Quiet, but still inside its expected length: a pause, not a stall.
        XCTAssertEqual(SynthesizerHealthPolicy.assess(speakAt: t0, didStartAt: started,
                                                      lastBoundaryAt: t0.addingTimeInterval(2),
                                                      characters: chars, rate: rate,
                                                      now: t0.addingTimeInterval(8)), .healthy)
        // Quiet and overrun.
        XCTAssertEqual(SynthesizerHealthPolicy.assess(speakAt: t0, didStartAt: started,
                                                      lastBoundaryAt: t0.addingTimeInterval(2),
                                                      characters: chars, rate: rate,
                                                      now: t0.addingTimeInterval(20)), .stalled)
    }

    func testExpectedDurationScalesWithRate() {
        let normal = SynthesizerHealthPolicy.expectedDuration(characters: 140, rate: AVSpeechUtteranceDefaultSpeechRate)
        let fast = SynthesizerHealthPolicy.expectedDuration(characters: 140, rate: AVSpeechUtteranceDefaultSpeechRate * 1.5)
        XCTAssertEqual(normal, 10, accuracy: 0.01)
        XCTAssertLessThan(fast, normal)
    }

    // MARK: - The service with a synthesizer that never calls back

    private final class SilentSynthesizer: SpeechSynthesizing {
        weak var delegate: (any AVSpeechSynthesizerDelegate)?
        var spoken = 0
        var stopped = 0
        func speak(_ utterance: AVSpeechUtterance) { spoken += 1 }
        func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { stopped += 1; return false }
    }

    private static let fastTiming = SynthesizerHealthPolicy.Timing(startTimeout: 0.2, boundarySilence: 0.2,
                                                                   slack: 0.1, pollInterval: 0.05)

    func testAWedgedEngineIsRebuiltRetriedOnceAndTheTurnCompletes() async {
        var made: [SilentSynthesizer] = []
        let service = TextToSpeechService(synthesizerFactory: {
            let synth = SilentSynthesizer()
            made.append(synth)
            return synth
        })
        service.synthesizerHealthTiming = Self.fastTiming

        let started = Date()
        let outcome = await service.speakWithSystemVoiceForTesting("The static pressure is point five.")

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the turn no longer waits for ever")
        XCTAssertEqual(outcome, .failed(reason: "engine never started"))
        XCTAssertEqual(made.count, 3, "the original plus one rebuild per failed attempt")
        XCTAssertEqual(made[0].spoken, 1)
        XCTAssertEqual(made[1].spoken, 1, "retried once, on the rebuilt synthesizer")
        XCTAssertEqual(made[2].spoken, 0)
        XCTAssertNil(made[0].delegate, "the wedged engine is detached so it cannot record a late outcome")
        XCTAssertTrue(made[2].delegate === service)
        XCTAssertEqual(service.synthesizerRebuilds, 2)
        XCTAssertNotNil(service.lastEngineFailureAt)
    }

    func testAMediaServicesResetReleasesTheWaitingUtterance() async {
        var made: [SilentSynthesizer] = []
        let service = TextToSpeechService(synthesizerFactory: {
            let synth = SilentSynthesizer()
            made.append(synth)
            return synth
        })
        // A long start timeout: only the reset can release this one in time.
        service.synthesizerHealthTiming = .init(startTimeout: 60, boundarySilence: 60, slack: 60, pollInterval: 0.05)
        let task = Task { await service.speakWithSystemVoiceForTesting("Checking the flame sensor.") }
        for _ in 0..<50 where made.first?.spoken != 1 { try? await Task.sleep(nanoseconds: 20_000_000) }
        service.handleMediaServicesReset()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed(reason: "audio services were reset"))
        XCTAssertEqual(made.count, 2)
    }

    func testFirstTerminalOutcomeStillWins() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 1)
        ledger.record(.tornDown(.bargeIn), liveGeneration: 1)
        ledger.record(.engineStalled, liveGeneration: 1)
        XCTAssertEqual(ledger.outcome(for: 1), .interrupted(by: .bargeIn))
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .engineNeverStarted, teardownCause: nil),
                       .failed(reason: "engine never started"))
    }

    // MARK: - The held utterance

    func testAHeldUtteranceBehindAnEngineFailureIsReplayedNotDropped() {
        let heldAt = t0
        let now = t0.addingTimeInterval(56)   // the field run: held 17:11:16, dropped 17:12:12
        XCTAssertFalse(TurnAdmissionPolicy.shouldReplayHeldUtterance(heldAt: heldAt, now: now,
                                                                     speechEngineFailedAt: nil))
        XCTAssertTrue(TurnAdmissionPolicy.shouldReplayHeldUtterance(heldAt: heldAt, now: now,
                                                                    speechEngineFailedAt: now.addingTimeInterval(-1)))
        // An engine failure from before the hold is not this utterance's excuse.
        XCTAssertFalse(TurnAdmissionPolicy.shouldReplayHeldUtterance(heldAt: heldAt, now: now,
                                                                     speechEngineFailedAt: heldAt.addingTimeInterval(-5)))
        XCTAssertTrue(TurnAdmissionPolicy.shouldReplayHeldUtterance(heldAt: heldAt, now: t0.addingTimeInterval(5),
                                                                    speechEngineFailedAt: nil))
    }

    func testTheAppReplaysThroughTheEngineAwarePolicy() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("speechEngineFailedAt: speechService.lastEngineFailureAt"))
    }
}

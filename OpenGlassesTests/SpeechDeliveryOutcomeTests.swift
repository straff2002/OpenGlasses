import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan FE P4 — the delivery outcome a speech utterance reports back.
///
/// Two halves. The decision table is asserted as a pure function, branch by branch, because
/// "`didCancel` means interrupted, unless we know it was a barge-in" is exactly the kind of rule
/// that rots silently. Then the real `TextToSpeechService` delegate methods are driven against
/// its ledger, so the mapping is not merely correct in isolation but is the one the engine
/// callbacks actually reach — a simulator has no speech engine and no audio route, so there is no
/// way to get at those callbacks through real playback.
@MainActor
final class SpeechDeliveryOutcomeTests: XCTestCase {

    // MARK: - The decision table

    func testSystemFinishIsCompleted() {
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .systemFinished, teardownCause: nil),
                       .completed)
    }

    func testSystemFinishIsCompletedEvenWithATeardownCauseRecorded() {
        // `didFinish` is the utterance reaching its end. A stop that arrived afterwards cannot
        // retroactively make a finished utterance an interrupted one.
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .systemFinished, teardownCause: .bargeIn),
                       .completed)
    }

    func testSystemCancelUsesTheRecordedCause() {
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .systemCancelled, teardownCause: .bargeIn),
                       .interrupted(by: .bargeIn))
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .systemCancelled, teardownCause: .stop),
                       .interrupted(by: .stop))
    }

    func testSystemCancelWithNoRecordedCauseIsANewUtterance() {
        // Nothing on this side recorded a stop, so the cancel came from `speak` replacing it.
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .systemCancelled, teardownCause: nil),
                       .interrupted(by: .newUtterance))
    }

    func testPlayerSuccessFlagSplitsCompletedFromFailed() {
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .playerFinished(success: true),
                                                    teardownCause: nil), .completed)
        guard case .failed = SpeechDeliveryLedger.outcome(for: .playerFinished(success: false),
                                                          teardownCause: nil) else {
            return XCTFail("an unsuccessful player finish is a failure, not a completion")
        }
    }

    func testPlayerFailureIsNotReportedAsAnInterruptionEvenDuringATeardown() {
        // The player's own flag is about the player. Reading it as "the wearer cut it off" would
        // offer a replay for a fault and hide a broken engine behind a friendly explanation.
        guard case .failed = SpeechDeliveryLedger.outcome(for: .playerFinished(success: false),
                                                          teardownCause: .bargeIn) else {
            return XCTFail("expected failed")
        }
    }

    func testDecodeAndStartFailuresAreFailures() {
        for signal in [SpeechDeliveryLedger.EngineSignal.playerDecodeFailed, .playbackDidNotStart,
                       .noEngineAvailable] {
            guard case .failed = SpeechDeliveryLedger.outcome(for: signal, teardownCause: nil) else {
                return XCTFail("\(signal) should be a failure")
            }
        }
    }

    func testTornDownCarriesItsOwnCause() {
        for cause in [SpeechDeliveryOutcome.Interruption.bargeIn, .stop, .newUtterance] {
            XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .tornDown(cause), teardownCause: nil),
                           .interrupted(by: cause))
        }
    }

    func testEverySuppressionReasonRoundTrips() {
        for reason in [SpeechDeliveryOutcome.SuppressionReason.muted, .noRoute, .silentMode,
                       .backgrounded] {
            XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .withheld(reason), teardownCause: nil),
                           .suppressed(reason: reason))
        }
    }

    func testMidChainCancellationDefaultsToStopNotANewUtterance() {
        // A cancellation between engines with no recorded cause is the task being cancelled, which
        // is a stop. `superseded` is the branch that means a replacement.
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .cancelledMidChain, teardownCause: nil),
                       .interrupted(by: .stop))
        XCTAssertEqual(SpeechDeliveryLedger.outcome(for: .superseded, teardownCause: nil),
                       .interrupted(by: .newUtterance))
    }

    func testOnlyInterruptedAndSuppressedOweAReplay() {
        XCTAssertTrue(SpeechDeliveryOutcome.interrupted(by: .bargeIn).owesReplay)
        XCTAssertTrue(SpeechDeliveryOutcome.suppressed(reason: .noRoute).owesReplay)
        XCTAssertFalse(SpeechDeliveryOutcome.completed.owesReplay)
        XCTAssertFalse(SpeechDeliveryOutcome.failed(reason: "x").owesReplay)
    }

    // MARK: - The ledger's rules

    func testFirstTerminalStateWins() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 3)
        ledger.teardownCause = .bargeIn
        ledger.record(.tornDown(.bargeIn), liveGeneration: 3)
        // The engine's own cancel callback arrives afterwards and knows nothing about the cause.
        ledger.record(.systemCancelled, liveGeneration: 3)
        XCTAssertEqual(ledger.outcome(for: 3), .interrupted(by: .bargeIn))
    }

    func testALateCallbackCannotMarkASuccessorUtteranceCompleted() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 5)
        // A newer `speak` has already taken generation 6; the old utterance's `didFinish` lands now.
        ledger.record(.systemFinished, liveGeneration: 6)
        XCTAssertEqual(ledger.outcome(for: 5), .completed, "it belongs to the utterance it started on")
        XCTAssertNil(ledger.outcome(for: 6), "and not to the one that replaced it")
    }

    func testADeadGenerationIsDropped() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 1)
        ledger.record(.systemFinished, for: 1, liveGeneration: 9)
        XCTAssertNil(ledger.outcome(for: 1), "a generation eight utterances old cannot matter")
    }

    func testTakeUsesTheFallbackWhenNothingWasRecorded() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 2)
        let outcome = ledger.take(generation: 2, fallback: .failed(reason: "nothing spoke it"),
                                  liveGeneration: 2)
        guard case .failed = outcome else { return XCTFail("expected the fallback") }
    }

    func testTakeConsumesTheRecordedOutcome() {
        var ledger = SpeechDeliveryLedger()
        ledger.beginUtterance(generation: 2)
        ledger.record(.systemFinished, liveGeneration: 2)
        XCTAssertEqual(ledger.take(generation: 2, fallback: .completed, liveGeneration: 2), .completed)
        XCTAssertNil(ledger.outcome(for: 2), "a taken outcome is not left behind to be taken twice")
    }

    func testBeginningAnUtteranceClearsTheTeardownCause() {
        var ledger = SpeechDeliveryLedger()
        ledger.teardownCause = .bargeIn
        ledger.beginUtterance(generation: 4)
        XCTAssertNil(ledger.teardownCause,
                     "the reason the last utterance stopped is not a reason about this one")
    }

    // MARK: - The real engine callbacks

    /// The service's own delegate methods, driven directly. They hop to the main actor, so each
    /// assertion follows a yield.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    func testDidFinishOnTheServiceRecordsCompleted() async {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: "hi"))
        await settle()
        XCTAssertEqual(service.deliveryLedger.outcome(for: 0), .completed)
    }

    func testDidCancelOnTheServiceRecordsTheBargeIn() async {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        service.deliveryLedger.teardownCause = .bargeIn
        service.speechSynthesizer(AVSpeechSynthesizer(), didCancel: AVSpeechUtterance(string: "hi"))
        await settle()
        XCTAssertEqual(service.deliveryLedger.outcome(for: 0), .interrupted(by: .bargeIn))
    }

    func testStopSpeakingRecordsItsOwnReason() {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        service.stopSpeaking(interruption: .bargeIn)
        XCTAssertEqual(service.deliveryLedger.outcome(for: 0), .interrupted(by: .bargeIn))
    }

    func testPlainStopSpeakingIsAStop() {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        service.stopSpeaking()
        XCTAssertEqual(service.deliveryLedger.outcome(for: 0), .interrupted(by: .stop))
    }

    func testPlayerFinishFlagReachesTheLedger() async {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        let player = try? AVAudioPlayer(data: Self.silentWAV)
        guard let player else { return XCTFail("could not build a player over the fixture WAV") }
        service.audioPlayerDidFinishPlaying(player, successfully: false)
        await settle()
        guard case .failed = service.deliveryLedger.outcome(for: 0) else {
            return XCTFail("an unsuccessful finish is a failure")
        }
    }

    func testDecodeErrorReachesTheLedger() async {
        let service = TextToSpeechService()
        service.deliveryLedger.beginUtterance(generation: 0)
        let player = try? AVAudioPlayer(data: Self.silentWAV)
        guard let player else { return XCTFail("could not build a player over the fixture WAV") }
        service.audioPlayerDecodeErrorDidOccur(player, error: nil)
        await settle()
        guard case .failed = service.deliveryLedger.outcome(for: 0) else {
            return XCTFail("a decode error is a failure")
        }
    }

    // MARK: - The route gate

    func testAnInjectedSuppressionIsReportedWithItsReasonAndNothingIsSpoken() async {
        let service = TextToSpeechService()
        service.suppressionCheck = { .silentMode }
        let outcome = await service.speakReporting("the agent finished")
        XCTAssertEqual(outcome, .suppressed(reason: .silentMode))
        XCTAssertFalse(service.isSpeaking)
    }

    func testEverySuppressionReasonIsReportedAsItself() async {
        for reason in [SpeechDeliveryOutcome.SuppressionReason.muted, .noRoute, .silentMode,
                       .backgrounded] {
            let service = TextToSpeechService()
            service.suppressionCheck = { reason }
            let outcome = await service.speakReporting("result")
            XCTAssertEqual(outcome, .suppressed(reason: reason))
        }
    }

    func testAnEmptyUtteranceIsAFailureNotACompletion() async {
        let service = TextToSpeechService()
        service.suppressionCheck = { nil }
        guard case .failed = await service.speakReporting("") else {
            return XCTFail("there is nothing honest to call a completion here")
        }
    }

    /// 44 bytes of WAV header and one silent frame — enough for `AVAudioPlayer` to initialise
    /// without any audio route, which is all these tests need from it.
    private static var silentWAV: Data {
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(38); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
        ascii("data"); u32(2); u16(0)
        return data
    }
}

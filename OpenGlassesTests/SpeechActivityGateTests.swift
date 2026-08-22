import XCTest
@testable import OpenGlasses

/// Plan CU P2 — the hysteresis between raw voice-activity scores and the two events
/// `EndOfTurnPolicy` reasons about. The stamping tests matter as much as the thresholds: an event
/// carrying the wrong *time* hides the very latency P1 exists to measure.
final class SpeechActivityGateTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    /// Feed a run of identical scores at a fixed hop, collecting every event.
    private func feed(_ gate: inout SpeechActivityGate,
                      score: Float,
                      from start: TimeInterval,
                      count: Int,
                      hop: TimeInterval = 0.032) -> [SpeechActivityGate.Event] {
        (0..<count).compactMap { gate.observe(score: score, at: at(start + Double($0) * hop)) }
    }

    // MARK: - Onset

    func testASingleNoisyHopDoesNotStartSpeech() {
        var gate = SpeechActivityGate()
        XCTAssertNil(gate.observe(score: 0.9, at: at(0)))
        XCTAssertFalse(gate.isSpeaking, "one hop above onset is a click, not a wearer")
    }

    func testSpeechStartsOnceItPersistsAndIsStampedAtTheOnset() {
        var gate = SpeechActivityGate()
        let events = feed(&gate, score: 0.9, from: 1.0, count: 10)
        XCTAssertEqual(events, [.speechStarted(at: at(1.0))],
                       "stamped at the first qualifying hop, not at the confirmation — the barge-in rider wants the earlier one")
        XCTAssertTrue(gate.isSpeaking)
    }

    func testAnInterruptedRunRestartsTheOnsetClock() {
        var gate = SpeechActivityGate()
        _ = gate.observe(score: 0.9, at: at(0.0))
        _ = gate.observe(score: 0.1, at: at(0.03))          // the run breaks
        let events = feed(&gate, score: 0.9, from: 0.06, count: 2)
        XCTAssertTrue(events.isEmpty, "the second run is only ~0.03 s old; it must not inherit the first's age")
    }

    // MARK: - Release, and the mistake that cuts a wearer off

    /// The expensive failure. A breath or an unvoiced consonant drops the score below onset but not
    /// below release, and nothing may happen.
    func testADipBetweenTheThresholdsDoesNotEndSpeech() {
        var gate = SpeechActivityGate()
        _ = feed(&gate, score: 0.9, from: 0.0, count: 10)
        XCTAssertTrue(gate.isSpeaking)

        let config = SpeechActivityGate.Configuration.default
        let between = (config.releaseThreshold + config.onsetThreshold) / 2
        let events = feed(&gate, score: between, from: 1.0, count: 40)   // ~1.3 s of dip
        XCTAssertTrue(events.isEmpty, "a dip below onset is mid-sentence, and ending the turn there is the bug")
        XCTAssertTrue(gate.isSpeaking)
    }

    func testShortSilenceDoesNotEndSpeechButSustainedSilenceDoes() {
        var gate = SpeechActivityGate()
        _ = feed(&gate, score: 0.9, from: 0.0, count: 10)

        let brief = feed(&gate, score: 0.0, from: 1.0, count: 5)          // ~0.16 s
        XCTAssertTrue(brief.isEmpty, "shorter than minSilenceDuration — a pause between words")
        XCTAssertTrue(gate.isSpeaking)

        let sustained = feed(&gate, score: 0.0, from: 1.16, count: 20)
        XCTAssertEqual(sustained.count, 1)
        XCTAssertFalse(gate.isSpeaking)
    }

    /// The stamp that decides whether P2 can be measured at all: speech-end is when the silence
    /// *began*, not when it was confirmed. Confirming folds `minSilenceDuration` into the wearer's
    /// dead air and hides it inside `perceivedLatency` — the same trap P1 documents one layer up.
    func testSpeechEndIsStampedWhenTheSilenceBeganNotWhenItWasConfirmed() {
        var gate = SpeechActivityGate()
        _ = feed(&gate, score: 0.9, from: 0.0, count: 10)

        let silenceBegan = 2.0
        let events = feed(&gate, score: 0.0, from: silenceBegan, count: 40)
        XCTAssertEqual(events, [.speechEnded(at: at(silenceBegan))])
    }

    /// A resumed sentence clears the pending silence, so the next real pause is timed from itself.
    func testResumedSpeechClearsThePendingSilence() {
        var gate = SpeechActivityGate()
        _ = feed(&gate, score: 0.9, from: 0.0, count: 10)
        _ = feed(&gate, score: 0.0, from: 1.0, count: 5)     // a pause, not yet an end
        _ = feed(&gate, score: 0.9, from: 1.2, count: 5)     // "…and another thing"

        let events = feed(&gate, score: 0.0, from: 2.0, count: 40)
        XCTAssertEqual(events, [.speechEnded(at: at(2.0))],
                       "the end belongs to the second pause; carrying the first would report an end before the wearer finished")
    }

    // MARK: - Configuration

    /// Not a style check. A release threshold at or above onset collapses the hysteresis and makes
    /// every mid-sentence dip an end of turn — the one failure this type exists to prevent.
    func testReleaseThresholdSitsBelowOnset() {
        let config = SpeechActivityGate.Configuration.default
        XCTAssertLessThan(config.releaseThreshold, config.onsetThreshold)
    }

    func testResetDropsEverythingAboutThePreviousUtterance() {
        var gate = SpeechActivityGate()
        _ = feed(&gate, score: 0.9, from: 0.0, count: 10)
        XCTAssertTrue(gate.isSpeaking)

        gate.reset()
        XCTAssertFalse(gate.isSpeaking)
        XCTAssertNil(gate.observe(score: 0.0, at: at(5.0)),
                     "silence after a reset is not the end of a turn that is no longer running")
    }
}

import XCTest
@testable import OpenGlasses

/// Plan CU P2 PR2 — `SpeechActivityGate.Configuration.silero`, scored in 256 ms chunks, and the
/// felt end-of-speech delay that chunk quantisation produces.
final class SileroGateConfigurationTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let hop = SpeechHopChunker.hopDuration
    /// The start time of chunk `n`.
    private func chunk(_ n: Int) -> Date { epoch.addingTimeInterval(Double(n) * hop) }

    /// Feed one score per chunk, from chunk 0, collecting (chunk index, event).
    private func run(_ scores: [Float], gate: inout SpeechActivityGate) -> [(Int, SpeechActivityGate.Event)] {
        scores.enumerated().compactMap { n, score in
            gate.observe(score: score, at: chunk(n)).map { (n, $0) }
        }
    }

    func testTheProvisionalNumbers() {
        let silero = SpeechActivityGate.Configuration.silero
        XCTAssertEqual(silero.onsetThreshold, 0.65)
        XCTAssertEqual(silero.releaseThreshold, 0.50)
        XCTAssertEqual(silero.onsetThreshold - silero.releaseThreshold, 0.15, accuracy: 1e-6,
                       "Silero's conventional release is onset − 0.15")
        XCTAssertEqual(silero.minSpeechDuration, 0.12)
        XCTAssertEqual(silero.minSilenceDuration, 0.5)
        XCTAssertLessThan(silero.minSpeechDuration, hop,
                          "shorter than a chunk, which is what makes it mean exactly two chunks")
    }

    func testTheDefaultConfigurationIsUnchanged() {
        let d = SpeechActivityGate.Configuration.default
        XCTAssertEqual(d, SpeechActivityGate.Configuration(onsetThreshold: 0.6, releaseThreshold: 0.35,
                                                           minSpeechDuration: 0.12, minSilenceDuration: 0.5))
    }

    func testOneIsolatedLoudChunkIsNeverSpeech() {
        var gate = SpeechActivityGate(configuration: .silero)
        let events = run([0.1, 0.99, 0.1, 0.1, 0.99, 0.2], gate: &gate)
        XCTAssertTrue(events.isEmpty, "a single loud 256 ms chunk is a door, not a wearer")
        XCTAssertFalse(gate.isSpeaking)
    }

    func testTwoConsecutiveChunksStartSpeechStampedAtTheFirst() {
        var gate = SpeechActivityGate(configuration: .silero)
        let events = run([0.1, 0.7, 0.7], gate: &gate)
        XCTAssertEqual(events.map(\.1), [.speechStarted(at: chunk(1))])
        XCTAssertEqual(events.first?.0, 2, "confirmed on the second chunk")
    }

    func testAChunkJustBelowOnsetDoesNotCountTowardsOnset() {
        var gate = SpeechActivityGate(configuration: .silero)
        XCTAssertTrue(run([0.64, 0.64, 0.64, 0.64], gate: &gate).isEmpty)
    }

    func testADipBetweenReleaseAndOnsetChangesNothing() {
        var gate = SpeechActivityGate(configuration: .silero)
        let scores: [Float] = [0.9, 0.9, 0.55, 0.6, 0.52, 0.9, 0.58, 0.58, 0.58, 0.58]
        let events = run(scores, gate: &gate)
        XCTAssertEqual(events.map(\.1), [.speechStarted(at: chunk(0))],
                       "a breath between 0.50 and 0.65 is still the wearer talking")
        XCTAssertTrue(gate.isSpeaking)
    }

    func testSpeechEndsStampedAtTheStartOfTheSilence() {
        var gate = SpeechActivityGate(configuration: .silero)
        let scores: [Float] = [0.9, 0.9, 0.9, 0.2, 0.2, 0.2, 0.2]
        let events = run(scores, gate: &gate)
        XCTAssertEqual(events.map(\.1), [.speechStarted(at: chunk(0)), .speechEnded(at: chunk(3))])
        XCTAssertEqual(events.last?.0, 5, "the third quiet chunk confirms 0.5 s of silence")
    }

    func testTwoQuietChunksAreNotEnough() {
        var gate = SpeechActivityGate(configuration: .silero)
        let events = run([0.9, 0.9, 0.2, 0.2, 0.9, 0.2, 0.2], gate: &gate)
        XCTAssertEqual(events.map(\.1), [.speechStarted(at: chunk(0))])
    }

    // MARK: - Restart across a format change

    func testARestartKeepsTheWearerTalkingButDropsTheRuns() {
        var gate = SpeechActivityGate(configuration: .silero)
        _ = run([0.9, 0.9, 0.2], gate: &gate)               // speaking, one quiet chunk counted
        gate.restart(speaking: gate.isSpeaking)
        XCTAssertTrue(gate.isSpeaking)
        // Silence after the flip is still heard as the end of speech, timed from the new audio.
        XCTAssertNil(gate.observe(score: 0.2, at: chunk(10)))
        XCTAssertNil(gate.observe(score: 0.2, at: chunk(11)))
        XCTAssertEqual(gate.observe(score: 0.2, at: chunk(12)), .speechEnded(at: chunk(10)))
    }

    func testARestartWhileSilentIsAReset() {
        var gate = SpeechActivityGate(configuration: .silero)
        _ = gate.observe(score: 0.9, at: chunk(0))            // a candidate onset
        gate.restart(speaking: false)
        XCTAssertNil(gate.observe(score: 0.9, at: chunk(5)), "the candidate went with the old audio")
        XCTAssertFalse(gate.isSpeaking)
    }

    // MARK: - Felt delay

    func testTheFeltDelayStepTable() {
        let rows: [(minSilence: TimeInterval, low: TimeInterval)] = [
            (0, 0.400),      // one chunk (0.256) is inside the 0.4 s grace
            (0.25, 0.512),
            (0.3, 0.768),    // 0.3 and 0.5 are the same three chunks
            (0.5, 0.768),
            (0.512, 0.768),  // an exact multiple does not round up a whole chunk
            (0.75, 1.024),
            (1.0, 1.280),
        ]
        for row in rows {
            let felt = SpeechActivityGate.feltEndOfTurnDelay(minSilence: row.minSilence, chunk: hop)
            XCTAssertEqual(felt.lowerBound, row.low, accuracy: 1e-9, "minSilence \(row.minSilence)")
            XCTAssertEqual(felt.upperBound - felt.lowerBound, hop, accuracy: 1e-9)
        }
        let shipped = SpeechActivityGate.feltEndOfTurnDelay(
            minSilence: SpeechActivityGate.Configuration.silero.minSilenceDuration, chunk: hop)
        XCTAssertLessThan(shipped.upperBound, SpeechContinuationPolicy.baseWindow,
                          "the worst case still beats the 2 s timer")
    }

    func testTheFeltDelayMatchesWhatTheGateDoes() {
        // Speech in chunks 0–3; the wearer's last word is inside chunk 3, so silence is first
        // seen in chunk 4. Speech-end becomes known when the confirming chunk has been captured.
        for minSilence in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let configuration = SpeechActivityGate.Configuration(
                onsetThreshold: 0.65, releaseThreshold: 0.5, minSpeechDuration: 0.12,
                minSilenceDuration: minSilence)
            var gate = SpeechActivityGate(configuration: configuration)
            let events = run([0.9, 0.9, 0.9, 0.9] + [Float](repeating: 0.1, count: 10), gate: &gate)
            guard let (confirming, event) = events.last, case .speechEnded(let at) = event else {
                return XCTFail("no speech end at minSilence \(minSilence)")
            }
            XCTAssertEqual(at, chunk(4))
            let known = chunk(confirming).addingTimeInterval(hop).timeIntervalSince(at)
            let felt = SpeechActivityGate.feltEndOfTurnDelay(minSilence: minSilence, chunk: hop, grace: 0)
            XCTAssertEqual(known, felt.lowerBound, accuracy: 1e-6, "minSilence \(minSilence)")
        }
    }
}

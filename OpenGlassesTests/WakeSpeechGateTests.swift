import XCTest
@testable import OpenGlasses

/// Synthetic PCM for the speech gate (Plan GU §5). Deterministic: a fixed-seed generator, so a
/// failure reproduces exactly.
enum SyntheticPCM {
    static let sampleRate: Double = 16_000
    static let bufferFrames = 1024

    private struct LCG {
        var state: UInt32
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) * 2 - 1
        }
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    static func scaled(_ x: [Float], toDBFS level: Float) -> [Float] {
        let current = rms(x)
        guard current > 0 else { return x }
        let target = powf(10, level / 20)
        return x.map { $0 * target / current }
    }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// White noise — broadband hiss, crossing zero thousands of times a second.
    static func hiss(seconds: Double, dBFS: Float, seed: UInt32 = 7) -> [Float] {
        var g = LCG(state: seed)
        return scaled((0..<Int(seconds * sampleRate)).map { _ in g.next() }, toDBFS: dBFS)
    }

    /// Low-passed noise — a room's steady background, inside the speech crossing band.
    static func roomNoise(seconds: Double, dBFS: Float, seed: UInt32 = 11) -> [Float] {
        var g = LCG(state: seed)
        var y: Float = 0
        let raw = (0..<Int(seconds * sampleRate)).map { _ -> Float in
            y += 0.2 * (g.next() - y)
            return y
        }
        return scaled(raw, toDBFS: dBFS)
    }

    /// A low sine — traffic, handling rumble.
    static func rumble(seconds: Double, dBFS: Float, hertz: Double = 40) -> [Float] {
        let raw = (0..<Int(seconds * sampleRate)).map { Float(sin(2 * .pi * hertz * Double($0) / sampleRate)) }
        return scaled(raw, toDBFS: dBFS)
    }

    /// Voiced-speech-like: a 200 Hz fundamental with harmonics, amplitude-modulated at a syllable
    /// rate.
    static func speechLike(seconds: Double, dBFS: Float) -> [Float] {
        let raw = (0..<Int(seconds * sampleRate)).map { i -> Float in
            let t = Double(i) / sampleRate
            let carrier = sin(2 * .pi * 200 * t) + 0.5 * sin(2 * .pi * 400 * t) + 0.25 * sin(2 * .pi * 800 * t)
            let envelope = 0.6 + 0.4 * sin(2 * .pi * 4 * t)
            return Float(carrier * envelope)
        }
        return scaled(raw, toDBFS: dBFS)
    }

    /// Room noise whose level climbs steadily from `from` to `to` dBFS.
    static func risingNoise(seconds: Double, from: Float, to: Float) -> [Float] {
        let base = roomNoise(seconds: seconds, dBFS: 0)
        let n = base.count
        return base.enumerated().map { i, s in
            let level = from + (to - from) * Float(i) / Float(n)
            return s * powf(10, level / 20)
        }
    }

    static func buffers(_ x: [Float]) -> [[Float]] {
        stride(from: 0, to: x.count, by: bufferFrames).map { Array(x[$0..<min($0 + bufferFrames, x.count)]) }
    }
}

final class EnergySpeechScorerTests: XCTestCase {

    private func scores(_ signal: [Float]) -> [Float] {
        var scorer = EnergySpeechScorer()
        return SyntheticPCM.buffers(signal).map { scorer.score($0, sampleRate: SyntheticPCM.sampleRate) }
    }

    func testDigitalSilenceScoresZero() {
        XCTAssertTrue(scores(SyntheticPCM.silence(seconds: 2)).allSatisfy { $0 == 0 })
    }

    func testSteadyNoiseAtSeveralLevelsStaysBelowRelease() {
        for level: Float in [-60, -45, -30, -20] {
            let s = scores(SyntheticPCM.roomNoise(seconds: 5, dBFS: level))
            XCTAssertLessThan(s.max() ?? 0, SpeechActivityGate.Configuration.wakeIdle.releaseThreshold,
                              "a steady room at \(level) dBFS is the floor, not speech")
        }
    }

    func testLowRumbleIsRejectedByTheCrossingBand() {
        let signal = SyntheticPCM.silence(seconds: 0.5) + SyntheticPCM.rumble(seconds: 2, dBFS: -15)
        XCTAssertTrue(scores(signal).allSatisfy { $0 == 0 })
    }

    func testHissIsRejectedByTheCrossingBand() {
        let signal = SyntheticPCM.silence(seconds: 0.5) + SyntheticPCM.hiss(seconds: 2, dBFS: -15)
        XCTAssertTrue(scores(signal).allSatisfy { $0 == 0 })
    }

    func testSpeechOverAQuietRoomScoresAboveOnset() {
        let signal = SyntheticPCM.roomNoise(seconds: 2, dBFS: -60)
            + SyntheticPCM.speechLike(seconds: 1, dBFS: -25)
        let s = scores(signal)
        let speechStart = Int(2 * SyntheticPCM.sampleRate) / SyntheticPCM.bufferFrames + 1
        XCTAssertGreaterThanOrEqual(s[speechStart], SpeechActivityGate.Configuration.wakeIdle.onsetThreshold,
                                    "onset within a buffer")
        XCTAssertTrue(s[..<(speechStart - 1)].allSatisfy { $0 < 0.35 })
    }

    func testQuieterThanTheAbsoluteFloorIsNeverSpeech() {
        let signal = SyntheticPCM.silence(seconds: 1) + SyntheticPCM.speechLike(seconds: 1, dBFS: -62)
        XCTAssertTrue(scores(signal).allSatisfy { $0 == 0 })
    }

    func testTheScoreMapsTheDBThresholdsOntoTheGate() {
        let t = EnergySpeechScorer.Thresholds.standard
        let g = SpeechActivityGate.Configuration.wakeIdle
        XCTAssertEqual(EnergySpeechScorer.mapExcess(t.onsetOverFloorDB, thresholds: t, gate: g), g.onsetThreshold,
                       accuracy: 1e-5)
        XCTAssertEqual(EnergySpeechScorer.mapExcess(t.releaseOverFloorDB, thresholds: t, gate: g),
                       g.releaseThreshold, accuracy: 1e-5)
        XCTAssertEqual(EnergySpeechScorer.mapExcess(0, thresholds: t, gate: g), 0)
        XCTAssertEqual(EnergySpeechScorer.mapExcess(100, thresholds: t, gate: g), 1)
        let strict = EnergySpeechScorer.Thresholds.strict
        XCTAssertLessThan(EnergySpeechScorer.mapExcess(11, thresholds: strict, gate: g), g.onsetThreshold,
                          "strict needs +13 dB")
    }

    func testProvisionalThresholdsAreThePlans() {
        let t = EnergySpeechScorer.Thresholds.standard
        XCTAssertEqual(t.absoluteFloorDBFS, -55)
        XCTAssertEqual(t.onsetOverFloorDB, 10)
        XCTAssertEqual(t.releaseOverFloorDB, 6)
        XCTAssertEqual(t.zeroCrossingBand, 150...5_000)
        XCTAssertEqual(SpeechActivityGate.Configuration.wakeIdle.minSpeechDuration, 0.10)
    }
}

final class WakeSpeechGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// Run PCM through the scorer and the gate; outputs with the second they happened at.
    private func run(_ signal: [Float], strict: Bool = false,
                     wakeMatchAt: Double? = nil) -> [(Double, WakeSpeechGate.Output)] {
        var scorer = EnergySpeechScorer(thresholds: strict ? .strict : .standard)
        var gate = WakeSpeechGate(strict: strict)
        var out: [(Double, WakeSpeechGate.Output)] = []
        let hop = Double(SyntheticPCM.bufferFrames) / SyntheticPCM.sampleRate
        for (i, buffer) in SyntheticPCM.buffers(signal).enumerated() {
            let t = Double(i) * hop
            if let wakeMatchAt, t >= wakeMatchAt, gate.recognizerOpen { gate.noteWakeMatched() }
            let score = scorer.score(buffer, sampleRate: SyntheticPCM.sampleRate)
            if let o = gate.observe(score: score, at: t0.addingTimeInterval(t)) { out.append((t, o)) }
        }
        return out
    }

    func testDigitalSilenceNeverOpens() {
        XCTAssertTrue(run(SyntheticPCM.silence(seconds: 10)).isEmpty)
    }

    func testSteadyNoiseNeverOpens() {
        for level: Float in [-50, -40, -30] {
            XCTAssertTrue(run(SyntheticPCM.roomNoise(seconds: 10, dBFS: level)).isEmpty, "\(level) dBFS")
        }
    }

    func testRumbleAndHissNeverOpen() {
        XCTAssertTrue(run(SyntheticPCM.silence(seconds: 1) + SyntheticPCM.rumble(seconds: 5, dBFS: -15)).isEmpty)
        XCTAssertTrue(run(SyntheticPCM.silence(seconds: 1) + SyntheticPCM.hiss(seconds: 5, dBFS: -15)).isEmpty)
    }

    func testARisingFloorNeverOpens() {
        // 0.5 dB/s — the room getting busier, not somebody talking.
        XCTAssertTrue(run(SyntheticPCM.risingNoise(seconds: 40, from: -50, to: -30)).isEmpty)
    }

    func testSpeechOpensPromptlyAndClosesAfterTheTail() {
        let signal = SyntheticPCM.roomNoise(seconds: 2, dBFS: -60)
            + SyntheticPCM.speechLike(seconds: 1.2, dBFS: -25)
            + SyntheticPCM.roomNoise(seconds: 4, dBFS: -60, seed: 3)
        let out = run(signal)
        guard case .open(let at)? = out.first?.1 else { return XCTFail("did not open: \(out)") }
        XCTAssertEqual(at.timeIntervalSince(t0), 2.0, accuracy: 0.15, "stamped at the onset hop")
        XCTAssertLessThan(out[0].0, 2.0 + 0.10 + 0.15, "open within min speech + a hop of the onset")
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].1, .close)
        // Speech ended at 3.2 s; release confirms after 0.3 s, then the 1.5 s tail.
        XCTAssertEqual(out[1].0, 3.2 + 0.3 + WakeSpeechGate.recognitionTail, accuracy: 0.25)
    }

    func testAWakeMatchKeepsTheRecognizerForTheTurn() {
        let signal = SyntheticPCM.roomNoise(seconds: 1, dBFS: -60)
            + SyntheticPCM.speechLike(seconds: 1, dBFS: -25)
            + SyntheticPCM.roomNoise(seconds: 4, dBFS: -60, seed: 5)
        let out = run(signal, wakeMatchAt: 1.5)
        XCTAssertEqual(out.map(\.1).filter { $0 == .close }.count, 0, "never closes under the turn")
    }

    func testStrictUsesTheShorterTail() {
        XCTAssertEqual(WakeSpeechGate(strict: true).tail, WakeSpeechGate.strictRecognitionTail)
        XCTAssertEqual(WakeSpeechGate(strict: false).tail, WakeSpeechGate.recognitionTail)
    }

    func testAGateOpenTooLongGivesUpGating() {
        var gate = WakeSpeechGate()
        var outputs: [WakeSpeechGate.Output] = []
        var t = 0.0
        while t < 62 {
            if let o = gate.observe(score: 0.9, at: t0.addingTimeInterval(t)) { outputs.append(o) }
            t += 0.064
        }
        XCTAssertEqual(outputs.first.map { if case .open = $0 { return true } else { return false } }, true)
        XCTAssertEqual(outputs.last, .giveUpGating, "a conversation nearby: back to continuous recognition")
        XCTAssertTrue(gate.gatingAbandoned)
        XCTAssertNil(gate.observe(score: 0, at: t0.addingTimeInterval(70)), "silent once abandoned")
        gate.reset()
        XCTAssertFalse(gate.gatingAbandoned)
        XCTAssertFalse(gate.recognizerOpen)
    }

    func testSpeechResumingInTheTailKeepsItOpen() {
        var gate = WakeSpeechGate()
        var outputs: [WakeSpeechGate.Output] = []
        func feed(_ score: Float, for seconds: Double, from start: Double) {
            var t = start
            while t < start + seconds {
                if let o = gate.observe(score: score, at: t0.addingTimeInterval(t)) { outputs.append(o) }
                t += 0.064
            }
        }
        feed(0.9, for: 1, from: 0)
        feed(0.0, for: 1.0, from: 1)      // ended, inside the tail
        feed(0.9, for: 1, from: 2)        // talking again
        XCTAssertFalse(outputs.contains(.close))
        XCTAssertEqual(outputs.filter { if case .open = $0 { return true } else { return false } }.count, 1)
    }
}

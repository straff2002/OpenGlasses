import XCTest
@testable import OpenGlasses

/// Instant Replay §8 — judging a measured frame series: even, bursty, stalled, reordered.
final class FrameCadenceAnalyzerTests: XCTestCase {

    private typealias Sample = FrameCadenceAnalyzer.Sample

    /// 15 fps captured and delivered evenly, arrival trailing capture by a steady 40 ms.
    private func even(count: Int = 150) -> [Sample] {
        (0..<count).map { i in
            let pts = Double(i) / 15
            return Sample(arrival: 1000 + pts + 0.040, presentation: pts)
        }
    }

    /// Captured evenly at 15 fps, delivered three at a time every 200 ms.
    private func bursty(count: Int = 150) -> [Sample] {
        (0..<count).map { i in
            let pts = Double(i) / 15
            let group = i / 3
            let arrival = 1000 + Double(group) * 0.2 + 0.2 + Double(i % 3) * 0.005
            return Sample(arrival: arrival, presentation: pts)
        }
    }

    func testAnEvenStreamNeedsNoPlayoutDelay() {
        let report = FrameCadenceAnalyzer.analyze(even())
        XCTAssertEqual(report.verdict, .even)
        XCTAssertEqual(report.bursts, 0)
        XCTAssertEqual(report.stalls, 0)
        XCTAssertEqual(report.gapMedian, 1.0 / 15, accuracy: 0.001)
        XCTAssertTrue(report.presentationEven)
        XCTAssertEqual(report.reordered, 0)
        XCTAssertEqual(report.lagP95, 0, accuracy: 0.001)
        XCTAssertEqual(report.recommendedPlayoutDelay, 0)
        XCTAssertEqual(report.framesPerSecond, 15, accuracy: 0.5)
    }

    func testBurstsAreFoundFromArrivalAgainstPresentation() {
        let report = FrameCadenceAnalyzer.analyze(bursty())
        XCTAssertEqual(report.verdict, .bursty)
        XCTAssertGreaterThan(report.bursts, 40, "three-frame bursts every 200 ms")
        XCTAssertTrue(report.presentationEven, "the glasses captured evenly; only delivery bunched")
        XCTAssertGreaterThan(report.lagP95, 0.1)
        XCTAssertGreaterThanOrEqual(report.gapMax, 0.18)
        // The delay that would hide the bunching: the lag spread rounded up to 10 ms, within cap.
        XCTAssertGreaterThanOrEqual(report.recommendedPlayoutDelay, report.lagP95)
        XCTAssertLessThanOrEqual(report.recommendedPlayoutDelay, 0.3)
        XCTAssertEqual((report.recommendedPlayoutDelay * 100).rounded(), report.recommendedPlayoutDelay * 100,
                       accuracy: 1e-6)
    }

    func testTwoFramesTogetherAreNotABurst() {
        // Pairs 5 ms apart, every 133 ms: bunched, but under the three-frame threshold.
        let samples = (0..<100).map { i -> Sample in
            let pts = Double(i) / 15
            let arrival = 1000 + Double(i / 2) * 0.1333 + Double(i % 2) * 0.005
            return Sample(arrival: arrival, presentation: pts)
        }
        XCTAssertEqual(FrameCadenceAnalyzer.analyze(samples).bursts, 0)
    }

    func testAStalledStreamIsCalledStalled() {
        var samples = even(count: 60)
        // Two half-second-plus silences.
        samples = samples.enumerated().map { index, s in
            let shift = index >= 20 ? (index >= 40 ? 1.6 : 0.8) : 0
            return Sample(arrival: s.arrival + shift, presentation: s.presentation.map { $0 + shift })
        }
        let report = FrameCadenceAnalyzer.analyze(samples)
        XCTAssertEqual(report.stalls, 2)
        XCTAssertEqual(report.verdict, .stalled)
        XCTAssertGreaterThanOrEqual(report.gapMax, 0.8)
    }

    func testReorderedPresentationTimesAreCountedAndNotEven() {
        var samples = even(count: 30)
        samples.swapAt(10, 11)
        let swapped = samples.enumerated().map { i, s in
            Sample(arrival: 1000 + Double(i) / 15, presentation: s.presentation)
        }
        let report = FrameCadenceAnalyzer.analyze(swapped)
        XCTAssertEqual(report.reordered, 1)
        XCTAssertFalse(report.presentationEven)
    }

    func testTooFewFramesIsInsufficient() {
        XCTAssertEqual(FrameCadenceAnalyzer.analyze(Array(even().prefix(2))).verdict, .insufficient)
    }

    func testSamplesWithoutPresentationTimesStillGiveArrivalGaps() {
        let samples = (0..<30).map { Sample(arrival: Double($0) / 15, presentation: nil) }
        let report = FrameCadenceAnalyzer.analyze(samples)
        XCTAssertEqual(report.verdict, .even)
        XCTAssertEqual(report.lagP95, 0)
        XCTAssertEqual(report.gapP95, 1.0 / 15, accuracy: 0.001)
    }

    func testPercentileIsNearestRank() {
        XCTAssertEqual(FrameCadenceAnalyzer.percentile([1, 2, 3, 4], 0.5), 2)
        XCTAssertEqual(FrameCadenceAnalyzer.percentile([1, 2, 3, 4], 0.95), 4)
        XCTAssertEqual(FrameCadenceAnalyzer.percentile([], 0.5), 0)
    }

    // MARK: - The recorder: a window per stream, once

    func testTheRecorderReportsOnceWhenTheWindowCloses() {
        let recorder = FrameCadenceRecorder(window: 1, isEnabled: { true })
        var reports = 0
        for i in 0..<40 {
            if recorder.record(arrival: Double(i) / 15, presentation: Double(i) / 15) != nil { reports += 1 }
        }
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(recorder.lastReport?.verdict, .even)
        recorder.streamReset()
        XCTAssertNil(recorder.record(arrival: 100, presentation: 100), "a new stream starts a new window")
        var again = 0
        for i in 1..<20 where recorder.record(arrival: 100 + Double(i) / 15, presentation: nil) != nil { again += 1 }
        XCTAssertEqual(again, 1)
    }

    func testTheRecorderDoesNothingWhileSwitchedOff() {
        let recorder = FrameCadenceRecorder(window: 0.1, isEnabled: { false })
        for i in 0..<20 { XCTAssertNil(recorder.record(arrival: Double(i), presentation: nil)) }
        XCTAssertNil(recorder.lastReport)
    }

    func testTheLogLineCarriesNumbersOnly() {
        let event = PrivacyLog.frameCadence(FrameCadenceAnalyzer.analyze(bursty()), width: 504, height: 896)
        let line = PrivacyEventEncoder.encode(event)
        XCTAssertTrue(line.contains("event=frameCadence"), line)
        XCTAssertTrue(line.contains("verdict=bursty"), line)
        XCTAssertTrue(line.contains("playoutDelay="), line)
        XCTAssertTrue(line.contains("width=504"), line)
    }

    func testTheSwitchIsOffByDefault() {
        let saved = UserDefaults.standard.object(forKey: "frameCadenceLoggingEnabled")
        defer { UserDefaults.standard.set(saved, forKey: "frameCadenceLoggingEnabled") }
        UserDefaults.standard.removeObject(forKey: "frameCadenceLoggingEnabled")
        XCTAssertFalse(Config.frameCadenceLoggingEnabled)
    }
}

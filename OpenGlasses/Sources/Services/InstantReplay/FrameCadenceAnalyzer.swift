import Foundation

/// Do the glasses deliver frames evenly, or in bursts? (Instant Replay §8.)
///
/// Every writer in the app — the long-form recorder, job clips, the broadcast encoder and the
/// replay buffer — stamps a frame with the moment it **arrives**. If the glasses deliver several
/// frames together and then nothing for a tenth of a second or more, a clip written by arrival time
/// plays unevenly: the bunched frames flash past and the picture freezes. This judges a measured
/// series, so the answer is a reading from a real stream rather than a guess.
///
/// Pure: the inputs are (arrival, presentation) pairs, in seconds on any clock each, in the order
/// the frames arrived.
enum FrameCadenceAnalyzer {

    struct Sample: Equatable {
        /// When the frame reached the app (`CACurrentMediaTime()` in the pipeline).
        let arrival: TimeInterval
        /// The sample's presentation timestamp, as the glasses stamped it. Nil when the sample
        /// carried none.
        let presentation: TimeInterval?
    }

    /// The thresholds the plan names, as values so a test can say them out loud.
    struct Thresholds: Equatable {
        /// Frames this close together arrived "together".
        var burstSpacing: TimeInterval = 0.020
        /// At least this many together…
        var burstMinimumFrames: Int = 3
        /// …followed by a gap at least this long is a burst.
        var burstFollowingGap: TimeInterval = 0.100
        /// No frame for this long is a stall, not cadence.
        var stallGap: TimeInterval = 0.500
        /// Presentation times are "even" when their p95 gap is within this factor of the median.
        var evenPresentationFactor: Double = 1.5
        /// Arrival lag spread below this needs no playout delay.
        var negligibleJitter: TimeInterval = 0.030
        /// The playout delay is never recommended above this; past it the stream has a bigger
        /// problem than cadence.
        var maximumPlayoutDelay: TimeInterval = 0.300
    }

    enum Verdict: String, Equatable {
        /// Too few frames to say anything.
        case insufficient
        /// Frames arrive about as evenly as they were captured.
        case even
        /// Frames arrive bunched: arrival-time stamping would play unevenly.
        case bursty
        /// The stream stopped for longer than a stall more than once; cadence is not the story.
        case stalled
    }

    struct Report: Equatable {
        let frames: Int
        let gapMedian: TimeInterval
        let gapP95: TimeInterval
        let gapMax: TimeInterval
        let bursts: Int
        let stalls: Int
        /// How far arrival lags capture, beyond the smallest lag seen: p95 and max. Large means a
        /// frame can turn up well after the one captured after it would have been shown.
        let lagP95: TimeInterval
        let lagMax: TimeInterval
        /// Presentation times arrive in order and evenly spaced.
        let presentationEven: Bool
        /// Frames whose presentation time is earlier than the frame before them.
        let reordered: Int
        /// The smallest delay a player would need to show these frames evenly: zero for an even
        /// stream, else the lag spread rounded up to 10 ms and capped.
        let recommendedPlayoutDelay: TimeInterval
        let verdict: Verdict
        /// Frames a second over the series, by arrival.
        var framesPerSecond: Double {
            guard frames > 1, gapMedian > 0 else { return 0 }
            return 1 / gapMedian
        }
    }

    static func analyze(_ samples: [Sample], thresholds t: Thresholds = Thresholds()) -> Report {
        guard samples.count >= 3 else {
            return Report(frames: samples.count, gapMedian: 0, gapP95: 0, gapMax: 0, bursts: 0,
                          stalls: 0, lagP95: 0, lagMax: 0, presentationEven: true, reordered: 0,
                          recommendedPlayoutDelay: 0, verdict: .insufficient)
        }

        let arrivals = samples.map(\.arrival)
        let gaps = zip(arrivals.dropFirst(), arrivals).map { max(0, $0 - $1) }
        let sortedGaps = gaps.sorted()
        let stalls = gaps.filter { $0 >= t.stallGap }.count

        // Bursts: a run of ≥ N frames each within `burstSpacing` of the one before, then a gap of
        // at least `burstFollowingGap`.
        var bursts = 0
        var run = 1
        for gap in gaps {
            if gap <= t.burstSpacing {
                run += 1
            } else {
                if run >= t.burstMinimumFrames, gap >= t.burstFollowingGap { bursts += 1 }
                run = 1
            }
        }

        // Presentation: order and evenness.
        let presentations = samples.compactMap(\.presentation)
        var reordered = 0
        for (later, earlier) in zip(presentations.dropFirst(), presentations) where later < earlier {
            reordered += 1
        }
        let presentationGaps = zip(presentations.dropFirst(), presentations).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        let presentationEven: Bool
        if presentationGaps.count < 2 {
            presentationEven = reordered == 0
        } else {
            let median = percentile(presentationGaps, 0.5)
            let p95 = percentile(presentationGaps, 0.95)
            presentationEven = reordered == 0 && median > 0 && p95 <= median * t.evenPresentationFactor
        }

        // Lag: arrival minus presentation, relative to the smallest lag. Only frames that carry a
        // presentation time take part.
        var lags: [TimeInterval] = []
        for sample in samples {
            if let pts = sample.presentation { lags.append(sample.arrival - pts) }
        }
        let lagSpread: [TimeInterval]
        if let minimum = lags.min() {
            lagSpread = lags.map { $0 - minimum }.sorted()
        } else {
            lagSpread = []
        }
        let lagP95 = lagSpread.isEmpty ? 0 : percentile(lagSpread, 0.95)
        let lagMax = lagSpread.last ?? 0

        let verdict: Verdict
        if stalls >= 2 {
            verdict = .stalled
        } else if bursts > 0 || lagP95 > t.burstFollowingGap {
            verdict = .bursty
        } else {
            verdict = .even
        }

        let delay: TimeInterval
        if verdict == .even && lagP95 < t.negligibleJitter {
            delay = 0
        } else {
            let base = max(lagP95, bursts > 0 ? t.burstFollowingGap : 0)
            delay = min(t.maximumPlayoutDelay, (base * 100).rounded(.up) / 100)
        }

        return Report(frames: samples.count,
                      gapMedian: percentile(sortedGaps, 0.5),
                      gapP95: percentile(sortedGaps, 0.95),
                      gapMax: sortedGaps.last ?? 0,
                      bursts: bursts, stalls: stalls,
                      lagP95: lagP95, lagMax: lagMax,
                      presentationEven: presentationEven, reordered: reordered,
                      recommendedPlayoutDelay: delay, verdict: verdict)
    }

    /// Nearest-rank percentile of an ascending array. Empty is zero.
    static func percentile(_ sorted: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
}

/// Collects one stream's (arrival, presentation) pairs for a fixed window and hands back a
/// report once, when the window closes (Instant Replay P0, the measurement).
///
/// Off unless the Developer panel's switch is on: the pipeline asks `isEnabled` per frame, and a
/// disabled recorder costs a lock and a bool. Thread-safe, because the glasses deliver frames on
/// whatever thread the SDK chooses.
final class FrameCadenceRecorder: @unchecked Sendable {

    /// The window the plan names: a minute of one stream.
    static let window: TimeInterval = 60

    /// The last finished report, for the Developer panel. Kept in memory only.
    static let shared = FrameCadenceRecorder()

    private let lock = NSLock()
    private var samples: [FrameCadenceAnalyzer.Sample] = []
    private var startedAt: TimeInterval?
    private var finishedForThisStream = false
    private var latest: FrameCadenceAnalyzer.Report?
    private let window: TimeInterval
    private let isEnabled: @Sendable () -> Bool

    init(window: TimeInterval = FrameCadenceRecorder.window,
         isEnabled: @escaping @Sendable () -> Bool = { Config.frameCadenceLoggingEnabled }) {
        self.window = window
        self.isEnabled = isEnabled
    }

    var lastReport: FrameCadenceAnalyzer.Report? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// One frame arrived. Returns the report exactly once per stream, on the first frame after
    /// the window has closed; nil otherwise.
    @discardableResult
    func record(arrival: TimeInterval, presentation: TimeInterval?) -> FrameCadenceAnalyzer.Report? {
        guard isEnabled() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !finishedForThisStream else { return nil }
        if startedAt == nil { startedAt = arrival }
        samples.append(.init(arrival: arrival, presentation: presentation))
        guard let startedAt, arrival - startedAt >= window else { return nil }
        let report = FrameCadenceAnalyzer.analyze(samples)
        latest = report
        samples = []
        finishedForThisStream = true
        return report
    }

    /// A new stream: measure it from its first frame.
    func streamReset() {
        lock.lock()
        defer { lock.unlock() }
        samples = []
        startedAt = nil
        finishedForThisStream = false
    }
}

/// The Developer panel's one line for a cadence reading — numbers only.
enum FrameCadenceSummary {
    static func line(_ r: FrameCadenceAnalyzer.Report) -> String {
        func ms(_ s: TimeInterval) -> String { "\(Int((s * 1000).rounded()))ms" }
        return "\(r.verdict.rawValue) · \(r.frames) frames · gap \(ms(r.gapMedian))/\(ms(r.gapP95))/\(ms(r.gapMax)) "
            + "· bursts \(r.bursts) · stalls \(r.stalls) · lag p95 \(ms(r.lagP95)) "
            + "· pts \(r.presentationEven ? "even" : "uneven") · delay \(ms(r.recommendedPlayoutDelay))"
    }
}

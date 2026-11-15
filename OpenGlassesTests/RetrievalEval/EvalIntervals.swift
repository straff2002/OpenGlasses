import Foundation

/// Confidence intervals for the local eval harnesses (`Scripts/retrieval-eval`,
/// `Scripts/table-lookup-eval`, and the simulator tests that share their cores).
///
/// An answer key holds 40–70 questions, so one question moves hit@k by 1.5–2.5 points. A point
/// estimate alone can't tell a +0.02 change from the luck of which questions were written. Two
/// tools answer that:
///
/// - `bootstrapInterval`: the percentile bootstrap over questions. Resample the run's per-question
///   values with replacement, take each resample's mean, and read the interval off the middle
///   `confidence` share of those means. It says how far the rate would move on another key of the
///   same size drawn from the same kind of questions.
/// - `pairedBootstrap`: two runs over the *same* questions (a baseline and a change). Each
///   question's difference (b − a) is resampled, so the noise both runs share (the hard questions
///   stay hard) cancels, and the interval is much tighter than two separate intervals overlapping.
///   When it excludes 0 the change is `better` or `worse`; otherwise it is `within noise`: not
///   shown to help.
///
/// Every metric here is higher-is-better (hit rates, reciprocal rank, cells matched), so `better`
/// means the difference is above 0.
///
/// Pure and deterministic: Foundation only, no app types, and a seeded generator (`SplitMix64`)
/// with its own index draw, so the same values and seed give the same interval on every machine
/// and every Swift version.
///
/// Edge cases, by design:
/// - no values: no interval (`nil`), printed as "-";
/// - one value, or all values equal: a zero-width interval at the mean. Every resample is the same,
///   so this says nothing about noise; the printed line carries the question count;
/// - paired inputs of different lengths: `Failure.mismatchedLengths` is thrown. The runners pair
///   questions by hash before they get here (`EvalOutcomes.pair`), so a mismatch is a caller bug;
/// - `resamples` below 1 or `confidence` outside (0, 1): a precondition failure.
enum EvalIntervals {

    /// The seed every runner uses unless told otherwise, so two runs of one key resample alike.
    static let defaultSeed: UInt64 = 20_261_115
    static let defaultResamples = 2_000
    static let defaultConfidence = 0.95

    // MARK: - The generator

    /// SplitMix64: a small, fast, well-mixed 64-bit generator with a fixed algorithm, so a seed
    /// means the same stream everywhere (the standard library's default generator is unseeded).
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// An index in `0..<count`, by the high word of a 64×64 multiply. Written out rather than
        /// `Int.random(in:using:)` so the draw can't change with the standard library; the bias is
        /// at most `count / 2^64`, nothing at a key's size.
        mutating func index(below count: Int) -> Int {
            precondition(count > 0, "an index needs a non-empty range")
            return Int(next().multipliedFullWidth(by: UInt64(count)).high)
        }
    }

    // MARK: - Results

    struct Interval: Equatable {
        /// The mean of the values themselves (not of the resamples).
        let mean: Double
        let lower: Double
        let upper: Double
        /// How many values (questions) it was computed over.
        let count: Int
        let resamples: Int
        let confidence: Double

        var width: Double { upper - lower }
        func contains(_ value: Double) -> Bool { lower <= value && value <= upper }

        /// "0.42 [0.31, 0.53]"; signed ("+0.03 [-0.01, +0.07]") for a difference.
        func formatted(signed: Bool = false) -> String {
            func f(_ x: Double) -> String {
                // Rounded as the runners' own rates are ("%.2f"), but never "-0.00": a difference
                // that rounds to nothing is nothing.
                let text = String(format: signed ? "%+.2f" : "%.2f", x)
                return text == "-0.00" ? (signed ? "+0.00" : "0.00") : text
            }
            return "\(f(mean)) [\(f(lower)), \(f(upper))]"
        }
    }

    enum Verdict: String, Equatable {
        case better
        case worse
        case withinNoise = "within noise"
    }

    /// A paired difference, b − a, with its interval and what it shows.
    struct Difference: Equatable {
        let interval: Interval
        var verdict: Verdict {
            if interval.lower > 0 { return .better }
            if interval.upper < 0 { return .worse }
            return .withinNoise
        }
        /// "+0.03 [-0.01, +0.07] within noise".
        var formatted: String { interval.formatted(signed: true) + " " + verdict.rawValue }
    }

    enum Failure: Error, Equatable {
        case mismatchedLengths(baseline: Int, current: Int)
    }

    // MARK: - The bootstrap

    /// The mean of each of `resamples` resamples of `values`, drawn with replacement. Exposed for
    /// tests; the intervals below read their percentiles off it.
    static func bootstrapMeans(_ values: [Double], resamples: Int = defaultResamples,
                               seed: UInt64 = defaultSeed) -> [Double] {
        precondition(resamples >= 1, "a bootstrap needs at least one resample")
        guard !values.isEmpty else { return [] }
        var rng = SplitMix64(seed: seed)
        let n = values.count
        var means: [Double] = []
        means.reserveCapacity(resamples)
        for _ in 0..<resamples {
            var sum = 0.0
            for _ in 0..<n { sum += values[rng.index(below: n)] }
            means.append(sum / Double(n))
        }
        return means
    }

    /// The percentile bootstrap interval of the mean of `values`, over questions. `nil` for no
    /// values.
    static func bootstrapInterval(values: [Double], resamples: Int = defaultResamples,
                                  confidence: Double = defaultConfidence,
                                  seed: UInt64 = defaultSeed) -> Interval? {
        precondition(confidence > 0 && confidence < 1, "confidence is a share between 0 and 1")
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let means = bootstrapMeans(values, resamples: resamples, seed: seed).sorted()
        let tail = (1 - confidence) / 2
        // Clamped to the mean, so the interval always holds the point estimate it is printed
        // beside (a percentile of resample means can sit a rounding error past it).
        return Interval(mean: mean,
                        lower: min(mean, quantile(means, tail)),
                        upper: max(mean, quantile(means, 1 - tail)),
                        count: values.count, resamples: resamples, confidence: confidence)
    }

    /// The paired bootstrap of b − a over the same questions, in the same order: `a` the baseline,
    /// `b` the change. `nil` for no questions; throws when the two runs differ in length.
    static func pairedBootstrap(a: [Double], b: [Double], resamples: Int = defaultResamples,
                                confidence: Double = defaultConfidence,
                                seed: UInt64 = defaultSeed) throws -> Difference? {
        guard a.count == b.count else { throw Failure.mismatchedLengths(baseline: a.count, current: b.count) }
        let differences = zip(a, b).map { $1 - $0 }
        return bootstrapInterval(values: differences, resamples: resamples, confidence: confidence, seed: seed)
            .map(Difference.init(interval:))
    }

    /// The `p` quantile of sorted values, interpolated between the two nearest order statistics.
    static func quantile(_ sorted: [Double], _ p: Double) -> Double {
        precondition(!sorted.isEmpty, "a quantile needs values")
        let h = Double(sorted.count - 1) * min(max(p, 0), 1)
        let low = Int(h.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (h - Double(low)) * (sorted[high] - sorted[low])
    }

    // MARK: - Lines

    /// One line of intervals for a run, counts and rates only:
    /// `<prefix> 95% intervals over 72 questions (bootstrap, 2000 resamples): hit@1 0.15 [0.07, 0.24] · …`.
    /// Each metric names its own question count when it differs from the first.
    static func intervalLine(prefix: String, metrics: [(name: String, values: [Double])],
                             resamples: Int = defaultResamples, confidence: Double = defaultConfidence,
                             seed: UInt64 = defaultSeed) -> String? {
        let measured = metrics.compactMap { metric in
            bootstrapInterval(values: metric.values, resamples: resamples, confidence: confidence, seed: seed)
                .map { (name: metric.name, interval: $0) }
        }
        guard let first = measured.first else { return nil }
        let parts = measured.map { m in
            "\(m.name) \(m.interval.formatted())" + (m.interval.count == first.interval.count ? "" : " (n=\(m.interval.count))")
        }
        return "\(prefix) \(Int((confidence * 100).rounded()))% intervals over \(first.interval.count) questions "
            + "(bootstrap, \(resamples) resamples): " + parts.joined(separator: " · ")
    }
}

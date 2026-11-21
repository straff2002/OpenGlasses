import Foundation

/// How long a session's hints took, from the question's final caption to the first card (Plan MO
/// §5): kept as samples and reported as p50 and p95, never an average, because one slow model call
/// in twenty is exactly what an average hides.
///
/// Pure. Percentiles are nearest-rank over the session's samples: p50 of 1, 2, 3, 4 is 2, p95 of
/// twenty samples is the nineteenth. The bands are the plan's target: good under 1.5 s, usable
/// under 3 s, broken over 5 s.
struct HintLatencyStats: Equatable, Sendable {

    enum Band: String, Equatable, Sendable {
        case good, usable, slow, broken
    }

    /// The most samples kept: a two-hour session hinting every 8 s fits.
    static let maxSamples = 1_000

    private(set) var samples: [TimeInterval] = []

    var count: Int { samples.count }

    mutating func record(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples.append(seconds)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    mutating func reset() { samples.removeAll() }

    var p50: TimeInterval? { Self.percentile(50, of: samples) }
    var p95: TimeInterval? { Self.percentile(95, of: samples) }

    /// The nearest-rank percentile: the smallest sample with at least `percent` % of the samples at
    /// or below it. Nil with no samples.
    static func percentile(_ percent: Double, of values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percent, 0), 100)
        let rank = max(1, Int((clamped / 100 * Double(sorted.count)).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }

    static func band(_ seconds: TimeInterval) -> Band {
        if seconds < 1.5 { return .good }
        if seconds < 3 { return .usable }
        if seconds <= 5 { return .slow }
        return .broken
    }
}

import Foundation

/// Plan CU P1 — a bounded in-memory store of recent `TurnTimeline`s, plus the in-flight bookkeeping
/// that lets one turn's marks be threaded through the existing turn path a call at a time instead of
/// assembled all at once and recorded in a single shot.
///
/// A service that records every voice turn and never forgets one is a memory leak with a slow fuse —
/// the cap is the point, not an afterthought. Two caps, because one alone isn't enough: `sealed` is
/// bounded by count *and* by an approximate byte total, so a run of turns with unusually long
/// `model` strings (a local model's filesystem path can run well past what a typical enum tag costs)
/// can't blow past a count-only limit without a single one of them looking like "too many turns".
///
/// `@MainActor` / `ObservableObject` / `@Published`, the same shape `SubsystemTestRunner` uses, so
/// the Developer-panel view observes this ledger exactly the way it already observes that runner.
@MainActor
final class TurnLedger: ObservableObject {

    /// Count, median, and mean for one derived metric within one cohort — see `stats(for:)`.
    struct Stats: Equatable {
        let count: Int
        let median: TimeInterval
        let mean: TimeInterval
    }

    /// The bounded, chronological (oldest → newest) history of sealed turns.
    @Published private(set) var sealed: [TurnTimeline] = []

    /// Turns `start`ed but not yet `seal`ed. Not `@Published` — the panel's "last N turns" list is a
    /// list of finished stories, and a turn that hasn't reached a stage worth drawing yet has
    /// nothing to contribute to it.
    private var inFlight: [UUID: TurnTimeline] = [:]

    /// How many turns are currently being tracked but not yet sealed.
    ///
    /// Published even though `inFlight` itself is not, and the distinction is the point: the panel
    /// says "N in flight" while a turn is running, which is the one moment the number is
    /// informative and the one moment a computed read off an unpublished dictionary would never
    /// refresh — the view would sit on "0 in flight" for the whole turn and correct itself to 0
    /// again at the seal. The timelines stay unpublished, so the "finished stories only" rule above
    /// still holds.
    @Published private(set) var inFlightCount = 0

    let maxCount: Int
    let maxBytes: Int
    private var sealedBytes = 0

    /// - Parameters:
    ///   - maxCount: sealed turns to retain. 200 is generous for a "last N turns" panel — this app
    ///     produces turns on the order of hundreds a day, not thousands an hour.
    ///   - maxBytes: approximate total footprint to retain, in `approximateByteSize(of:)` units.
    ///     256 KB is far more than 200 turns cost at their fixed size alone; this bound exists for
    ///     the pathological case — many turns with unusually long `model` names — not the common one.
    init(maxCount: Int = 200, maxBytes: Int = 256 * 1024) {
        self.maxCount = max(0, maxCount)
        self.maxBytes = max(0, maxBytes)
    }

    // MARK: - Lifecycle: start, mark/update, seal
    //
    // "Marks arriving for an unknown/sealed turn must be dropped harmlessly, never crash" — every
    // mutator below shares that contract. The turn path calls these from a dozen sites scattered
    // across the app, TTS, and LLM services; a superseded turn's late mark landing here after its
    // replacement has already sealed must never be the thing that crashes a voice interaction. It
    // just has nowhere left to land.

    /// Begin tracking `timeline` (a fresh one by default). Returns its id — equal to
    /// `timeline.id` — for the caller to thread through `mark`/`update` and the eventual `seal`.
    @discardableResult
    func start(_ timeline: TurnTimeline = TurnTimeline()) -> UUID {
        inFlight[timeline.id] = timeline
        inFlightCount = inFlight.count
        return timeline.id
    }

    /// Record `stage` at `time` on the in-flight turn `id`. A thin, named convenience over
    /// `update(_:_:)` for the single most common call — every stage transition on every turn.
    func mark(_ id: UUID, _ stage: TurnTimeline.Stage, at time: Date) {
        update(id) { $0.mark(stage, at: time) }
    }

    /// Apply an arbitrary mutation to the in-flight turn `id` — a tag, an accumulator,
    /// `abandoned`/`interrupted`, whatever `TurnTimeline`'s own mutating API already expresses.
    ///
    /// That API (`addToolTime`, the tag vars, `mark` itself, …) is the right vocabulary; the ledger
    /// doesn't re-declare it as a wall of one-line forwarders that would just be a second copy to
    /// keep in sync the next time the timeline grows a field.
    func update(_ id: UUID, _ mutate: (inout TurnTimeline) -> Void) {
        guard var timeline = inFlight[id] else { return }
        mutate(&timeline)
        inFlight[id] = timeline
    }

    /// Move `id` from in-flight to `sealed`, evicting the oldest sealed turns if the ring is now
    /// over either bound. A second `seal` of the same id, or an id that was never `start`ed, is a
    /// no-op.
    ///
    /// There is no separate "abandon" entry point: `abandoned`/`interrupted` are tags like any
    /// other (set them via `update` before sealing), and a partial timeline seals exactly like a
    /// complete one — cut short, it's still the most informative record of where that turn stopped.
    func seal(_ id: UUID) {
        guard let timeline = inFlight.removeValue(forKey: id) else { return }
        inFlightCount = inFlight.count
        sealed.append(timeline)
        sealedBytes += Self.approximateByteSize(of: timeline)
        trimToCapacity()
    }

    /// The current state of `id`, in-flight or sealed. `nil` if it's neither — never started, or
    /// aged out of the ring.
    func turn(_ id: UUID) -> TurnTimeline? {
        inFlight[id] ?? sealed.first { $0.id == id }
    }

    /// Drop everything, in-flight and sealed alike. The Developer panel's "clear" action.
    func reset() {
        inFlight.removeAll()
        inFlightCount = 0
        sealed.removeAll()
        sealedBytes = 0
    }

    private func trimToCapacity() {
        while !sealed.isEmpty, sealed.count > maxCount || sealedBytes > maxBytes {
            sealedBytes -= Self.approximateByteSize(of: sealed.removeFirst())
        }
    }

    /// Approximate in-memory footprint of one sealed timeline, in bytes.
    ///
    /// Deliberately not a real measurement — `TurnTimeline` is a value type with no heap indirection
    /// except its optional `model` string, and Swift has no cheap way to size a struct at runtime
    /// regardless. What the cap needs to catch is the one field that can grow without bound while
    /// everything else stays a fixed handful of bytes: a local model's filesystem path can run to a
    /// hundred-plus characters. So: a flat allowance for the marks, tags, and accumulators, plus the
    /// model name's real length. Not `private` — tests size `maxBytes` against this directly instead
    /// of duplicating the estimate.
    static func approximateByteSize(of timeline: TurnTimeline) -> Int {
        fixedFootprint + (timeline.model?.utf8.count ?? 0)
    }

    private static let fixedFootprint = 200

    // MARK: - Aggregates
    //
    // Grouped by `TurnTimeline.Cohort`, never flattened across it: an 8 kHz HFP mic and the phone's
    // 48 kHz mic are two populations for every timing here, and so are a network TTS engine and an
    // on-device one. Keying every result by `Cohort` makes pooling them a type error rather than a
    // discipline someone has to remember at every call site.

    /// `count`/`median`/`mean` of `metric`, evaluated over every sealed turn and grouped by cohort.
    ///
    /// A turn for which `metric` returns `nil` — an abandoned turn with no `firstAudioAt`, say —
    /// contributes no data point, exactly as `TurnTimeline`'s own derived properties already treat a
    /// missing mark. The median sits next to the mean, never instead of it: one slow 30 s turn
    /// should not be able to move the headline the way it moves an average.
    ///
    /// Typical call: `ledger.stats(for: \.perceivedLatency)`.
    func stats(for metric: (TurnTimeline) -> TimeInterval?) -> [TurnTimeline.Cohort: Stats] {
        var byCohort: [TurnTimeline.Cohort: [TimeInterval]] = [:]
        for timeline in sealed {
            guard let value = metric(timeline) else { continue }
            byCohort[timeline.cohort, default: []].append(value)
        }
        return byCohort.mapValues(Self.summarize)
    }

    /// `stats(for: \.perceivedLatency)` — the headline metric, pre-aggregated, named for what the
    /// panel leads with rather than for the key path that computes it.
    var perceivedLatencyByCohort: [TurnTimeline.Cohort: Stats] { stats(for: \.perceivedLatency) }

    private static func summarize(_ values: [TimeInterval]) -> Stats {
        let sorted = values.sorted()
        let mean = sorted.reduce(0.0, +) / Double(sorted.count)
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return Stats(count: sorted.count, median: median, mean: mean)
    }

    // MARK: - Debug export

    /// Plain-text dump of the sealed history plus per-cohort perceived-latency stats, for the
    /// Settings → Advanced → Developer "copy diagnostics" action. Text, not JSON: nothing parses
    /// this back, a developer reads it, so legibility wins (see also Plan CU P1 item 5 — no sink, no
    /// push; this on-device export is the entire surface).
    func debugExport(now: Date = Date()) -> String {
        var lines = [
            "OpenGlasses turn ledger — \(sealed.count) turns sealed, \(inFlightCount) in flight " +
            "(cap \(maxCount) turns / \(maxBytes) bytes)",
            "Exported \(ISO8601DateFormatter().string(from: now))",
            "",
        ]

        for timeline in sealed {
            var line = "\(timeline.id.uuidString.prefix(8))  \(Self.cohortLabel(timeline.cohort))"
            if let seconds = timeline.perceivedLatency { line += "  perceived=\(Self.formatSeconds(seconds))" }
            if timeline.abandoned { line += "  ABANDONED" }
            if timeline.interrupted { line += "  INTERRUPTED" }
            lines.append(line)
        }

        lines.append("")
        lines.append("Perceived latency by cohort (median / mean / n):")
        let byCohort = perceivedLatencyByCohort
        if byCohort.isEmpty {
            lines.append("  (no sealed turn has reached first audio yet)")
        }
        for (cohort, stat) in byCohort.sorted(by: { Self.cohortLabel($0.key) < Self.cohortLabel($1.key) }) {
            lines.append("  \(Self.cohortLabel(cohort)): median=\(Self.formatSeconds(stat.median))  " +
                         "mean=\(Self.formatSeconds(stat.mean))  n=\(stat.count)")
        }

        return lines.joined(separator: "\n")
    }

    private static func cohortLabel(_ cohort: TurnTimeline.Cohort) -> String {
        "\(cohort.backend?.label ?? "unknown")/\(cohort.ttsEngine?.rawValue ?? "unknown")/" +
        "\(cohort.micRoute?.rawValue ?? "unknown")"
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }
}

import Foundation

/// Plan KK — when a thread's timeline has grown enough that its oldest entries should become one.
/// Pure: it says *what* to merge; writing the merged text is the summary pass's job.
///
/// Two tiers, because a phone conversation is far shorter than a month at a desk. When
/// `threshold` chunks are waiting, the oldest `batch` of them become one merged entry and the
/// newest stay as a buffer; when `threshold` merged entries exist, the oldest `batch` of those
/// become one. A merge only takes entries whose spans run on from each other with nothing missing
/// between them — a merged entry's span claims every message inside it, and claiming a gap would
/// hide it from coverage for good.
enum TimelineMergePlanner {

    /// How many entries of a tier must exist before its oldest are merged.
    static let threshold = 6
    /// How many of the oldest are merged at once; `threshold - batch` stay as they are.
    static let batch = 4

    struct Plan: Equatable {
        /// The entries to replace, oldest first.
        let sourceIDs: [String]
        let sourceTier: TimelineEntry.Tier
        let firstMessageID: String
        let lastMessageID: String
        let startedAt: Date
        let endedAt: Date

        /// The merged entry the summary pass writes once it has text for this span.
        func entry(id: String, text: String) -> TimelineEntry {
            TimelineEntry(id: id, firstMessageID: firstMessageID, lastMessageID: lastMessageID,
                          startedAt: startedAt, endedAt: endedAt, tier: .merged, text: text)
        }

        /// `entries` with the sources replaced by `merged`, in the place the oldest source held.
        func applying(_ merged: TimelineEntry, to entries: [TimelineEntry]) -> [TimelineEntry] {
            let sources = Set(sourceIDs)
            guard let at = entries.firstIndex(where: { sources.contains($0.id) }) else { return entries }
            var result = entries
            result.removeAll { sources.contains($0.id) }
            result.insert(merged, at: min(at, result.count))
            return result
        }
    }

    /// The next merge, chunks first, or nil when neither tier is due.
    ///
    /// - Parameter messageIDs: the thread's conversational message ids in order, which is what
    ///   orders the entries and proves their spans meet. An entry whose span no longer resolves is
    ///   never merged.
    ///
    /// A redacted entry is never merged, and never merged across: it is left out before the runs
    /// are found, so the entries either side of it do not meet.
    static func nextMerge(entries: [TimelineEntry], messageIDs: [String]) -> Plan? {
        let positions = TimelineEntry.positions(of: messageIDs)
        let placed = entries.filter { !$0.isRedacted }
            .compactMap { entry in entry.span(in: positions).map { (entry, $0) } }
            .sorted { ($0.1.lowerBound, $0.1.upperBound) < ($1.1.lowerBound, $1.1.upperBound) }
        return plan(.chunk, in: placed) ?? plan(.merged, in: placed)
    }

    private static func plan(_ tier: TimelineEntry.Tier,
                             in placed: [(TimelineEntry, ClosedRange<Int>)]) -> Plan? {
        let ofTier = placed.filter { $0.0.tier == tier }
        guard ofTier.count >= threshold else { return nil }
        // The oldest run of `batch` that meets end to start (an overlap is fine; a hole is not).
        for start in 0...(ofTier.count - batch) {
            let run = ofTier[start..<(start + batch)]
            var reach = run.first!.1.upperBound
            var meets = true
            for (_, span) in run.dropFirst() {
                guard span.lowerBound <= reach + 1 else { meets = false; break }
                reach = max(reach, span.upperBound)
            }
            guard meets else { continue }
            let first = run.first!
            let last = run.max { $0.1.upperBound < $1.1.upperBound }!
            return Plan(sourceIDs: run.map { $0.0.id }, sourceTier: tier,
                        firstMessageID: first.0.firstMessageID, lastMessageID: last.0.lastMessageID,
                        startedAt: run.map { $0.0.startedAt }.min()!,
                        endedAt: run.map { $0.0.endedAt }.max()!)
        }
        return nil
    }
}

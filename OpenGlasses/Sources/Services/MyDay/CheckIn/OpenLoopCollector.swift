import Foundation

/// What the check-in has to say, after §2's rules: the loops in the order they are said, and the
/// sources that could not be read (said on the phone, never by inventing an empty list).
struct OpenLoopCollection: Equatable, Sendable {
    let loops: [OpenLoop]
    let unavailable: [OpenLoopSource]

    init(loops: [OpenLoop], unavailable: [OpenLoopSource] = []) {
        self.loops = loops
        self.unavailable = unavailable
    }

    var isEmpty: Bool { loops.isEmpty }

    static let empty = OpenLoopCollection(loops: [])
}

/// Plan LE §2 — what counts and in what order. Pure: the loops, tonight's dismissals, the clock
/// and the wearer's calendar are all inputs. Each source has already applied its own "counts
/// when" (an unresolved held entry from today or yesterday, a reminder due today or overdue, …);
/// the collector applies the rules every source shares, in order:
///
/// 1. Drop anything dismissed tonight, unless its fingerprint changed since.
/// 2. Drop anything dated after today: tomorrow is the morning briefing's job.
/// 3. Merge duplicates: a loop another loop `covers` counts once, as the one that covers it (a
///    reminder that is a goal step's action counts as the step). The pairs are found before rule 1
///    runs, so a dismissed step keeps its reminder out with it.
/// 4. Rank: approvals; then the job's loose ends (report, held close, parts, deferred task,
///    hand-off — decision 11); then overdue items oldest first; then today's by due time; then
///    undated items by `since`. Ties by the source's place in the table, then by id.
enum OpenLoopCollector {

    /// `said` (P1) is the loops already said today, in the same id → fingerprint shape as the
    /// dismissals: the scheduled check-in passes it so a loop said once today — by the check-in or
    /// asked for after its time — is not said again unless it changed. It is filtered like a
    /// dismissal, alongside it.
    static func collect(_ loops: [OpenLoop], unavailable: [OpenLoopSource] = [],
                        dismissed: [String: String], said: [String: String] = [:],
                        now: Date, calendar: Calendar) -> OpenLoopCollection {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now.addingTimeInterval(24 * 60 * 60)

        // The same loop read twice (two readers, or one reader repeating itself) is one loop.
        var seen = Set<String>()
        let unique = loops.filter { seen.insert($0.id).inserted }

        // Rule 3's pairs are found before anything is dropped: the step and its reminder are one
        // thing, so clearing the step tonight keeps its reminder out too, rather than letting it
        // come back on its own.
        let covered = unique.reduce(into: Set<String>()) { $0.formUnion($1.covers) }
        let merged = unique
            .filter { !OpenLoopDismissals.isDismissed($0, in: dismissed)                    // rule 1
                && !OpenLoopDismissals.isDismissed($0, in: said) }
            .filter { loop in loop.dueAt.map { $0 < startOfTomorrow } ?? true }           // rule 2
            .filter { !covered.contains($0.id) }                                           // rule 3

        let ranked = merged.sorted { lhs, rhs in                                          // rule 4
            let l = rankKey(lhs, now: now)
            let r = rankKey(rhs, now: now)
            if l.band != r.band { return l.band < r.band }
            if l.within != r.within { return l.within < r.within }
            if l.when != r.when { return l.when < r.when }
            if lhs.source.tableOrder != rhs.source.tableOrder {
                return lhs.source.tableOrder < rhs.source.tableOrder
            }
            return lhs.id < rhs.id
        }

        var sources = Set<OpenLoopSource>()
        let unread = unavailable.filter { sources.insert($0).inserted }
            .sorted { $0.tableOrder < $1.tableOrder }
        return OpenLoopCollection(loops: ranked, unavailable: unread)
    }

    /// Readings from several readers, flattened: the loops of every reader that could be read, and
    /// every source of the ones that could not.
    static func collect(readings: [(sources: [OpenLoopSource], reading: OpenLoopReading)],
                        dismissed: [String: String], said: [String: String] = [:],
                        now: Date, calendar: Calendar) -> OpenLoopCollection {
        var loops: [OpenLoop] = []
        var unavailable: [OpenLoopSource] = []
        for (sources, reading) in readings {
            switch reading {
            case .read(let found): loops += found
            case .unavailable: unavailable += sources
            }
        }
        return collect(loops, unavailable: unavailable, dismissed: dismissed, said: said,
                       now: now, calendar: calendar)
    }

    /// Read every reader fresh and collect what they found.
    @MainActor
    static func gather(_ readers: [OpenLoopSourceReading], dismissed: [String: String],
                       said: [String: String] = [:],
                       now: Date, calendar: Calendar) async -> OpenLoopCollection {
        var readings: [(sources: [OpenLoopSource], reading: OpenLoopReading)] = []
        for reader in readers {
            readings.append((reader.sources, await reader.readOpenLoops(now: now, calendar: calendar)))
        }
        return collect(readings: readings, dismissed: dismissed, said: said, now: now, calendar: calendar)
    }

    // MARK: - Rule 4

    private struct RankKey {
        /// 0 approvals, 1 the job's loose ends, 2 overdue, 3 due later today, 4 undated.
        let band: Int
        /// Within a band: the job's order, and a failed send before a staged one.
        let within: Int
        /// The moment the band sorts by.
        let when: Date
    }

    private static func rankKey(_ loop: OpenLoop, now: Date) -> RankKey {
        if loop.source == .approval {
            return RankKey(band: 0, within: 0, when: loop.since)
        }
        if let jobOrder = loop.source.jobOrder {
            return RankKey(band: 1, within: jobOrder * 2 + (loop.failed ? 0 : 1), when: loop.since)
        }
        guard let due = loop.dueAt else {
            return RankKey(band: 4, within: 0, when: loop.since)
        }
        return due < now
            ? RankKey(band: 2, within: 0, when: due)
            : RankKey(band: 3, within: 0, when: due)
    }
}

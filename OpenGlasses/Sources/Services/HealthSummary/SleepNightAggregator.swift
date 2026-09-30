import Foundation

/// Last night's sleep, reduced to the numbers a spoken answer uses.
struct SleepNight: Codable, Equatable, Sendable {
    /// Minutes spent in each tracked stage, from the single source that recorded stages.
    struct StageTotals: Codable, Equatable, Sendable {
        let core: TimeInterval
        let deep: TimeInterval
        let rem: TimeInterval
    }

    /// Start of the local day the night ended on — the morning after.
    let morning: Date
    /// When the night's reading window closes (14:00 on `morning`). A summary computed before
    /// this may be of a night still in progress.
    let windowEnd: Date
    /// Time asleep in the main sleep session; nil when only time in bed was recorded.
    let asleep: TimeInterval?
    /// Time in bed around the main session; nil when no source recorded it.
    let inBed: TimeInterval?
    /// Stage totals when a stage-tracking source recorded the night; nil otherwise.
    let stages: StageTotals?
    /// Breaks of five minutes or more between asleep intervals inside the main session.
    let awakenings: Int
    /// When these numbers were read.
    let asOf: Date
}

/// Turns raw sleep-analysis samples into one night.
///
/// - "Last night" is every sample overlapping 18:00 yesterday → 14:00 today, local time.
/// - Sources are merged, not added: when any source recorded stages (a watch, a ring), the asleep
///   timeline comes from the staged sources only, so a phone's coarse "asleep" block cannot pad the
///   total; otherwise every source's asleep intervals are unioned.
/// - The night is the **main session**: asleep intervals separated by less than three hours belong
///   to the same session (a split night is one night), and the session with the most sleep wins, so
///   an afternoon nap inside the window is not counted.
/// - Stage totals come from the one staged source with the most staged time, so two stage trackers
///   worn together are not double-counted.
enum SleepNightAggregator {

    /// Gaps shorter than this keep two asleep intervals in one session.
    static let sessionGap: TimeInterval = 3 * 3600
    /// A break at least this long counts as waking.
    static let awakeningMinimum: TimeInterval = 5 * 60

    /// 18:00 on the day before `now` → 14:00 on `now`'s day.
    static func window(endingOn now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday)
            ?? yesterday.addingTimeInterval(18 * 3600)
        let end = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today)
            ?? today.addingTimeInterval(14 * 3600)
        return DateInterval(start: start, end: end)
    }

    static func aggregate(_ samples: [SleepSample], now: Date, calendar: Calendar) -> SleepNight? {
        let window = window(endingOn: now, calendar: calendar)
        let morning = calendar.startOfDay(for: now)
        let clipped = samples.compactMap { clip($0, to: window) }
        guard !clipped.isEmpty else { return nil }

        let stagedSources = Set(clipped.filter { $0.stage.isStaged }.map(\.sourceID))
        let asleepSamples = clipped.filter {
            $0.stage.isAsleep && (stagedSources.isEmpty || stagedSources.contains($0.sourceID))
        }
        let inBedIntervals = union(clipped.filter { $0.stage == .inBed }.map { ($0.start, $0.end) })

        guard let main = mainSession(of: union(asleepSamples.map { ($0.start, $0.end) })) else {
            // In bed, never recorded asleep: a phone sleep schedule on its own.
            guard let bed = mainSession(of: inBedIntervals) else { return nil }
            return SleepNight(morning: morning, windowEnd: window.end, asleep: nil,
                              inBed: total(bed), stages: nil, awakenings: 0, asOf: now)
        }

        let session = DateInterval(start: main.first!.start, end: main.last!.end)
        let asleep = total(main)
        let awakenings = zip(main, main.dropFirst())
            .filter { $1.start.timeIntervalSince($0.end) >= awakeningMinimum }
            .count

        // In-bed time that touches the session, widened by the session gap so an in-bed block that
        // starts a little before the first asleep sample still belongs to this night.
        let widened = DateInterval(start: session.start.addingTimeInterval(-sessionGap),
                                   end: session.end.addingTimeInterval(sessionGap))
        let bedAroundSession = inBedIntervals.filter { $0.start < widened.end && $0.end > widened.start }
        let inBed = bedAroundSession.isEmpty ? nil : total(bedAroundSession)

        let stages = stageTotals(clipped, stagedSources: stagedSources, within: session)
        return SleepNight(morning: morning, windowEnd: window.end, asleep: asleep, inBed: inBed,
                          stages: stages, awakenings: awakenings, asOf: now)
    }

    // MARK: - Pieces

    private static func clip(_ sample: SleepSample, to window: DateInterval) -> SleepSample? {
        let start = max(sample.start, window.start)
        let end = min(sample.end, window.end)
        guard end > start else { return nil }
        return SleepSample(start: start, end: end, stage: sample.stage, sourceID: sample.sourceID)
    }

    /// Merge overlapping or touching intervals; the result is sorted and disjoint.
    static func union(_ intervals: [(Date, Date)]) -> [DateInterval] {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged: [DateInterval] = []
        for (start, end) in sorted {
            if let last = merged.last, start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, end))
            } else {
                merged.append(DateInterval(start: start, end: end))
            }
        }
        return merged
    }

    private static func total(_ intervals: [DateInterval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }

    /// Split disjoint sorted intervals into sessions at gaps of `sessionGap` or more, and return the
    /// session with the most time in it (the later one on a tie).
    private static func mainSession(of intervals: [DateInterval]) -> [DateInterval]? {
        var sessions: [[DateInterval]] = []
        for interval in intervals {
            if let lastEnd = sessions.last?.last?.end, interval.start.timeIntervalSince(lastEnd) < sessionGap {
                sessions[sessions.count - 1].append(interval)
            } else {
                sessions.append([interval])
            }
        }
        return sessions.max { total($0) <= total($1) }
    }

    private static func stageTotals(_ samples: [SleepSample], stagedSources: Set<String>,
                                    within session: DateInterval) -> SleepNight.StageTotals? {
        func stagedTime(_ source: String) -> TimeInterval {
            total(union(samples.filter { $0.sourceID == source && $0.stage.isStaged }
                .map { ($0.start, $0.end) }))
        }
        // The busiest staged source; ties broken by name so the choice is deterministic.
        guard let source = stagedSources.sorted().max(by: { stagedTime($0) < stagedTime($1) }) else {
            return nil
        }
        func time(in stage: SleepStage) -> TimeInterval {
            let intervals = samples
                .filter { $0.sourceID == source && $0.stage == stage }
                .compactMap { sample -> (Date, Date)? in
                    let start = max(sample.start, session.start), end = min(sample.end, session.end)
                    return end > start ? (start, end) : nil
                }
            return total(union(intervals))
        }
        let totals = SleepNight.StageTotals(core: time(in: .asleepCore), deep: time(in: .asleepDeep),
                                            rem: time(in: .asleepREM))
        return totals.core + totals.deep + totals.rem > 0 ? totals : nil
    }
}

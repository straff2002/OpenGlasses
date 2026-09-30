import Foundation

/// Today's steps, and — when there is enough history to say — the wearer's usual count by now.
struct StepComparison: Codable, Equatable, Sendable {
    /// Steps so far today, as of `asOf`.
    let today: Double
    /// The median of recent days' counts at the same clock time; nil when fewer than
    /// `StepBaseline.minimumUsableDays` days were usable.
    let usualByNow: Double?
    /// How many history days went into `usualByNow`.
    let usableDays: Int
    /// When the count was read.
    let asOf: Date
}

/// "Usual by now": the median of each of the previous 14 days' cumulative count at the same clock
/// time. A day whose whole total is under 500 steps is ignored — that is a phone left on a desk,
/// not a quiet day — and with fewer than five usable days there is no comparison at all, only
/// today's count. The median rather than the mean, so one long hike does not move "usual".
enum StepBaseline {

    static let historyDays = 14
    static let minimumDayTotal: Double = 500
    static let minimumUsableDays = 5

    static func compare(today: Double, history: [DayStepSample], asOf: Date) -> StepComparison {
        let usable = history.filter { $0.dayTotal >= minimumDayTotal }.map(\.byNow)
        let usual = usable.count >= minimumUsableDays ? median(usable) : nil
        return StepComparison(today: today, usualByNow: usual, usableDays: usable.count, asOf: asOf)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// One query range per history day, newest first: the day's start, the same clock time as
    /// `now` on that day, and the day's end.
    struct DayRange: Equatable {
        let dayStart: Date
        let sameTime: Date
        let dayEnd: Date
    }

    static func historyRanges(now: Date, calendar: Calendar) -> [DayRange] {
        let today = calendar.startOfDay(for: now)
        let time = calendar.dateComponents([.hour, .minute, .second], from: now)
        return (1...historyDays).compactMap { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            let sameTime = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                         second: time.second ?? 0, of: dayStart) ?? dayStart
            return DayRange(dayStart: dayStart, sameTime: min(sameTime, dayEnd), dayEnd: dayEnd)
        }
    }
}

import Foundation

/// The two heart-rate numbers a spoken answer uses.
///
/// - **Latest**: the newest reading, only if it is at most two hours old; an older one is not
///   "your heart rate", it is history.
/// - **Resting**: today's resting rate, else the most recent one from the last three days — the
///   phraser names which day it was.
struct HeartRateSummary: Codable, Equatable, Sendable {
    let latest: HeartRateReading?
    let resting: HeartRateReading?
    /// When these numbers were read.
    let asOf: Date

    static let recentWindow: TimeInterval = 2 * 3600
    static let restingLookbackDays = 3

    /// Where to start looking for resting readings: the start of the day three days before today.
    static func restingSearchStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -restingLookbackDays, to: today) ?? today
    }

    static func summarize(latest: HeartRateReading?, resting: [HeartRateReading],
                          now: Date, calendar: Calendar) -> HeartRateSummary {
        HeartRateSummary(latest: recent(latest, now: now),
                         resting: mostRecentResting(resting, now: now, calendar: calendar),
                         asOf: now)
    }

    /// The reading if it is no more than `recentWindow` old and not in the future.
    static func recent(_ reading: HeartRateReading?, now: Date) -> HeartRateReading? {
        guard let reading else { return nil }
        let age = now.timeIntervalSince(reading.date)
        return age >= 0 && age <= recentWindow ? reading : nil
    }

    static func mostRecentResting(_ readings: [HeartRateReading], now: Date,
                                  calendar: Calendar) -> HeartRateReading? {
        let earliest = restingSearchStart(now: now, calendar: calendar)
        return readings
            .filter { $0.date >= earliest && $0.date <= now }
            .max { $0.date < $1.date }
    }
}

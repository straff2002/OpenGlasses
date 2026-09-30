import Foundation
@testable import OpenGlasses

/// Shared fixtures for the health-summary tests: a fixed calendar and locale, a date builder, and a
/// fake reader standing in for HealthKit.
enum HealthFixture {
    static let timeZone = TimeZone(identifier: "UTC")!
    static let locale = Locale(identifier: "en_US")

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }

    /// A time on a day in October 2026 (UTC). `day` 15 is "today" in most tests.
    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    static let now = at(15, 9, 0)

    static var phraser: HealthSummaryPhraser {
        HealthSummaryPhraser(locale: locale, calendar: calendar)
    }

    static func sleep(_ start: Date, _ end: Date, _ stage: SleepStage,
                      source: String = "watch") -> SleepSample {
        SleepSample(start: start, end: end, stage: stage, sourceID: source)
    }

    static func hours(_ h: Double) -> TimeInterval { h * 3600 }
}

@MainActor
final class FakeHealthReader: HealthSampleReading {
    var authorization: HealthAuthorizationState = .requested
    var grantsOnRequest = false
    var readError: HealthReadError?

    var latest: HeartRateReading?
    var resting: [HeartRateReading] = []
    var sleep: [SleepSample] = []
    /// Steps in a range; defaults to nothing.
    var steps: (Date, Date) -> Double = { _, _ in 0 }

    private(set) var requestCount = 0
    private(set) var readCount = 0

    func authorizationState() async -> HealthAuthorizationState { authorization }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        if grantsOnRequest { authorization = .requested }
        return grantsOnRequest
    }

    private func check() throws {
        readCount += 1
        if let readError { throw readError }
    }

    func latestHeartRate(since: Date) async throws -> HeartRateReading? {
        try check()
        guard let latest, latest.date >= since else { return nil }
        return latest
    }

    func restingHeartRates(from: Date, to: Date) async throws -> [HeartRateReading] {
        try check()
        return resting.filter { $0.date >= from && $0.date <= to }
    }

    func sleepSamples(from: Date, to: Date) async throws -> [SleepSample] {
        try check()
        return sleep.filter { $0.end > from && $0.start < to }
    }

    func cumulativeSteps(from: Date, to: Date) async throws -> Double {
        try check()
        return steps(from, to)
    }
}

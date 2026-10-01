import CoreLocation
import Foundation
import WeatherKit
@testable import OpenGlasses

/// Builders for weather tests. Everything is a plain `WeatherReport`: no test makes a WeatherKit
/// request.
enum WeatherFixtures {

    /// 2026-10-01 09:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_845_200)

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func startOfDay(offset days: Int) -> Date {
        let start = utcCalendar.startOfDay(for: now)
        return utcCalendar.date(byAdding: .day, value: days, to: start)!
    }

    static func current(_ condition: WeatherCondition = .partlyCloudy,
                        temperatureC: Double = 14, apparentC: Double = 12,
                        windKmh: Double = 18, humidity: Double = 0.62) -> WeatherReport.Current {
        .init(temperatureC: temperatureC, apparentTemperatureC: apparentC,
              condition: condition, windKmh: windKmh, humidity: humidity)
    }

    static func day(_ offset: Int, _ condition: WeatherCondition = .partlyCloudy,
                    high: Double = 17, low: Double = 9, chance: Double = 0.1) -> WeatherReport.Day {
        .init(date: startOfDay(offset: offset), highC: high, lowC: low,
              condition: condition, precipitationChance: chance)
    }

    static let threeDays = [day(0), day(1, .rain, high: 15, low: 8, chance: 0.8), day(2, .clear, high: 19, low: 10)]

    static func minute(_ offset: Int, wet: Bool, kind: Precipitation = .rain) -> WeatherReport.Minute {
        .init(date: now.addingTimeInterval(Double(offset) * 60),
              precipitation: wet ? kind : .none,
              precipitationChance: wet ? 0.8 : 0.05,
              intensityMillimetresPerHour: wet ? 1.2 : 0)
    }

    /// An hour of minutes, wet exactly where `wetMinutes` says.
    static func hour(wet wetMinutes: Set<Int>, kind: Precipitation = .rain) -> [WeatherReport.Minute] {
        (0..<60).map { minute($0, wet: wetMinutes.contains($0), kind: kind) }
    }

    static func alert(_ summary: String, source: String = "MetService",
                      severity: WeatherSeverity = .moderate) -> WeatherReport.Alert {
        .init(summary: summary, source: source, region: nil, severity: severity)
    }

    static func report(current: WeatherReport.Current = current(),
                       days: [WeatherReport.Day] = threeDays,
                       minutes: [WeatherReport.Minute]? = nil,
                       alerts: [WeatherReport.Alert]? = nil) -> WeatherReport {
        WeatherReport(current: current, days: days, minutes: minutes, alerts: alerts)
    }
}

/// A provider that answers from a canned report (or throws) and records what it was asked.
final class FakeWeatherProvider: WeatherProviding, @unchecked Sendable {
    var result: Result<WeatherReport, Error>
    private(set) var requestedLocations: [CLLocation] = []

    init(_ result: Result<WeatherReport, Error> = .success(WeatherFixtures.report())) {
        self.result = result
    }

    func report(for location: CLLocation) async throws -> WeatherReport {
        requestedLocations.append(location)
        return try result.get()
    }
}

extension WeatherTool {
    /// A tool on fakes throughout: fixed fix, fixed geocoder, metric units, fixed clock.
    @MainActor
    static func testing(
        provider: FakeWeatherProvider = FakeWeatherProvider(),
        fix: CLLocation? = CLLocation(latitude: -41.286461, longitude: 174.776230),
        geocoded: [String: CLLocation] = [:],
        allowed: Bool = true,
        units: WeatherUnits = .metric,
        onAnswered: @escaping @MainActor () -> Void = {}
    ) -> WeatherTool {
        WeatherTool(dependencies: .init(
            provider: provider,
            currentLocation: { fix },
            geocode: { geocoded[$0] },
            placeName: { _ in "Wellington" },
            units: { units },
            now: { WeatherFixtures.now },
            isAllowed: { allowed },
            onAnswered: onAnswered
        ))
    }
}

import CoreLocation
import Foundation
import WeatherKit

/// Where weather comes from. The live implementation is WeatherKit; tests hand in a fake so no
/// request is ever made from a unit test.
protocol WeatherProviding: Sendable {
    func report(for location: CLLocation) async throws -> WeatherReport
}

/// Apple's WeatherKit — the only weather source in the app.
///
/// One request per answer: current conditions, the daily forecast, the minute forecast (absent
/// where the region has none) and active alerts, in a single `weather(for:including:)` call.
/// The request is WeatherKit's own, authenticated by the app's WeatherKit entitlement and App
/// Service; Avenkin owns no transport for it, so it has no `NetworkRoute` (the same rule as
/// MusicKit and MapKit search). Medical Local Only is enforced by the callers before this runs.
struct WeatherKitProvider: WeatherProviding {

    func report(for location: CLLocation) async throws -> WeatherReport {
        let (current, daily, minute, alerts) = try await WeatherService.shared.weather(
            for: location,
            including: .current, .daily, .minute, .alerts
        )
        return WeatherReport(
            current: .init(
                temperatureC: current.temperature.converted(to: .celsius).value,
                apparentTemperatureC: current.apparentTemperature.converted(to: .celsius).value,
                condition: current.condition,
                windKmh: current.wind.speed.converted(to: .kilometersPerHour).value,
                humidity: current.humidity
            ),
            days: daily.forecast.prefix(4).map { day in
                WeatherReport.Day(
                    date: day.date,
                    highC: day.highTemperature.converted(to: .celsius).value,
                    lowC: day.lowTemperature.converted(to: .celsius).value,
                    condition: day.condition,
                    precipitationChance: day.precipitationChance
                )
            },
            minutes: minute.map { forecast in
                forecast.forecast.map { item in
                    WeatherReport.Minute(
                        date: item.date,
                        precipitation: item.precipitation,
                        precipitationChance: item.precipitationChance,
                        intensityMillimetresPerHour: Self.millimetresPerHour(item.precipitationIntensity)
                    )
                }
            },
            alerts: alerts.map { list in
                list.map { alert in
                    WeatherReport.Alert(
                        summary: alert.summary,
                        source: alert.source,
                        region: alert.region,
                        severity: alert.severity
                    )
                }
            }
        )
    }

    /// WeatherKit reports precipitation intensity as a `Measurement<UnitSpeed>` — a depth of water
    /// per unit time. 1 mm/h is 0.001 m per 3,600 s.
    static func millimetresPerHour(_ intensity: Measurement<UnitSpeed>) -> Double {
        intensity.converted(to: .metersPerSecond).value * 3_600_000
    }
}

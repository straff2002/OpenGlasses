import Foundation
import WeatherKit

/// One weather answer's worth of data, as plain values.
///
/// WeatherKit's own structs (`CurrentWeather`, `DayWeather`, `MinuteWeather`, `WeatherAlert`) have
/// no public initialisers, so nothing built on them could be tested without a live request. The
/// live provider copies what the answers need into this type once, and everything downstream —
/// the phraser, the rain outlook, My Day — reads only this. Temperatures are Celsius and speeds
/// km/h here; `WeatherUnits` converts for the wearer at the last step.
struct WeatherReport: Equatable, Sendable {

    struct Current: Equatable, Sendable {
        var temperatureC: Double
        var apparentTemperatureC: Double
        var condition: WeatherCondition
        var windKmh: Double
        /// 0...1, as WeatherKit reports it.
        var humidity: Double
    }

    struct Day: Equatable, Sendable {
        /// The start of the day in the forecast location's time zone.
        var date: Date
        var highC: Double
        var lowC: Double
        var condition: WeatherCondition
        /// 0...1.
        var precipitationChance: Double
    }

    struct Minute: Equatable, Sendable {
        var date: Date
        var precipitation: Precipitation
        /// 0...1.
        var precipitationChance: Double
        var intensityMillimetresPerHour: Double
    }

    struct Alert: Equatable, Sendable {
        var summary: String
        /// The agency that issued it — "National Weather Service", "Met Office".
        var source: String
        var region: String?
        var severity: WeatherSeverity
    }

    var current: Current
    /// Today first, when WeatherKit's daily forecast starts today.
    var days: [Day]
    /// `nil` where the region has no minute forecast. An empty array is a forecast with no minutes
    /// left in it, which is not the same thing and is treated as unknown too.
    var minutes: [Minute]?
    /// `nil` where the region has no alert coverage; empty where it has and nothing is active.
    var alerts: [Alert]?
}

/// Why a weather answer could not be given, in the words the wearer hears.
enum WeatherFetchFailure: Error, Equatable {
    /// WeatherKit refused the request: the capability or App Service is not live for this build yet,
    /// or Apple denied it.
    case serviceUnavailable
    /// No network, or the request timed out.
    case offline
    /// Neither a location fix nor a place that could be found.
    case noLocation
    /// A named place that the phone's geocoder could not find.
    case placeNotFound(String)

    var spokenMessage: String {
        switch self {
        case .serviceUnavailable:
            return "Apple Weather isn't available to Avenkin right now, so I can't get the weather."
        case .offline:
            return "I can't reach Apple Weather without a connection, so I can't get the weather right now."
        case .noLocation:
            return "I can't get the weather right now because your location isn't available. Please make sure location services are enabled."
        case .placeNotFound(let place):
            return "I couldn't find \(place), so I can't get its weather."
        }
    }

    /// Classifies whatever the provider threw. Anything that is not a recognisable network failure
    /// is read as the service refusing, which is what an unactivated WeatherKit looks like.
    static func classify(_ error: Error) -> WeatherFetchFailure {
        if let failure = error as? WeatherFetchFailure { return failure }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .offline }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return .offline
        }
        return .serviceUnavailable
    }
}

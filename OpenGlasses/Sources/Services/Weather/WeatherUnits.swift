import Foundation

/// The units a weather answer is spoken in, chosen by the phone rather than guessed from a region
/// code. `UnitTemperature(forLocale:usage: .weather)` honours the Temperature setting in iOS
/// Settings as well as the region, so a New Zealand phone set to Fahrenheit gets Fahrenheit.
struct WeatherUnits: Equatable, Sendable {

    enum Temperature: Equatable, Sendable {
        case celsius
        case fahrenheit

        var symbol: String { self == .celsius ? "°C" : "°F" }
    }

    enum Speed: Equatable, Sendable {
        case kilometresPerHour
        case milesPerHour
        case metresPerSecond

        var label: String {
            switch self {
            case .kilometresPerHour: return "km/h"
            case .milesPerHour: return "mph"
            case .metresPerSecond: return "m/s"
            }
        }
    }

    var temperature: Temperature
    var speed: Speed

    static let metric = WeatherUnits(temperature: .celsius, speed: .kilometresPerHour)

    static func forLocale(_ locale: Locale) -> WeatherUnits {
        let temperatureUnit = UnitTemperature(forLocale: locale, usage: .weather)
        let speedUnit = UnitSpeed(forLocale: locale, usage: .wind)
        let temperature: Temperature = temperatureUnit == .fahrenheit ? .fahrenheit : .celsius
        let speed: Speed
        switch speedUnit {
        case .milesPerHour: speed = .milesPerHour
        case .metersPerSecond: speed = .metresPerSecond
        default: speed = .kilometresPerHour
        }
        return WeatherUnits(temperature: temperature, speed: speed)
    }

    /// Whole degrees in the wearer's unit, with its symbol: "18°C", "64°F".
    func temperature(_ celsius: Double) -> String {
        let value = temperature == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Self.wholeNumber(value))\(temperature.symbol)"
    }

    /// Whole units of speed: "15 km/h", "9 mph", "4 m/s".
    func speed(_ kilometresPerHour: Double) -> String {
        let value: Double
        switch speed {
        case .kilometresPerHour: value = kilometresPerHour
        case .milesPerHour: value = kilometresPerHour * 0.621371
        case .metresPerSecond: value = kilometresPerHour / 3.6
        }
        return "\(Self.wholeNumber(value)) \(speed.label)"
    }

    /// Rounded half away from zero, and never "-0".
    private static func wholeNumber(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return rounded == 0 ? 0 : rounded
    }
}

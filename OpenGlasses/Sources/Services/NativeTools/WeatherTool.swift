import Foundation
import CoreLocation

/// Fetches current weather from the free Open-Meteo API.
/// Uses LocationService for default coordinates; supports optional lat/lon override.
final class WeatherTool: NativeTool, @unchecked Sendable {
    let name = "get_weather"
    let description = "Get current weather and 3-day forecast for the user's location or a specified location."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "latitude": [
                "type": "number",
                "description": "Latitude (optional, defaults to user's current location)"
            ],
            "longitude": [
                "type": "number",
                "description": "Longitude (optional, defaults to user's current location)"
            ],
            "location": [
                "type": "string",
                "description": "Location name for context (optional)"
            ]
        ],
        "required": [] as [String]
    ]

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(args: [String: Any]) async throws -> String {
        let (lat, lon) = resolveCoordinates(args: args)

        guard let lat, let lon else {
            return "I can't get the weather right now because your location isn't available. Please make sure location services are enabled."
        }

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m&daily=temperature_2m_max,temperature_2m_min,weather_code&timezone=auto&forecast_days=3"

        guard let url = URL(string: urlString) else {
            return "Failed to build weather request URL."
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return "Weather service is temporarily unavailable."
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Couldn't parse weather data."
        }

        // Reverse geocode for location name
        let locationName = await reverseGeocode(lat: lat, lon: lon) ?? args["location"] as? String

        return formatWeather(json: json, locationName: locationName)
    }

    // MARK: - Private

    @MainActor
    private func resolveCoordinates(args: [String: Any]) -> (Double?, Double?) {
        if let lat = args["latitude"] as? Double, let lon = args["longitude"] as? Double {
            return (lat, lon)
        }
        if let location = locationService.currentLocation {
            return (location.coordinate.latitude, location.coordinate.longitude)
        }
        return (nil, nil)
    }

    private func reverseGeocode(lat: Double, lon: Double) async -> String? {
        guard let place = await GeocodingHelper.reverseGeocode(latitude: lat, longitude: lon) else { return nil }
        return place.cityState ?? place.fullAddress
    }

    private func formatWeather(json: [String: Any], locationName: String?) -> String {
        guard let current = json["current"] as? [String: Any],
              let daily = json["daily"] as? [String: Any] else {
            return "Couldn't read weather data."
        }

        let useFahrenheit = Locale.current.region?.identifier == "US"

        let temp = current["temperature_2m"] as? Double ?? 0
        let feelsLike = current["apparent_temperature"] as? Double ?? 0
        let weatherCode = current["weather_code"] as? Int ?? 0
        let windSpeed = current["wind_speed_10m"] as? Double ?? 0
        let humidity = current["relative_humidity_2m"] as? Int ?? 0

        let maxTemps = daily["temperature_2m_max"] as? [Double] ?? []
        let minTemps = daily["temperature_2m_min"] as? [Double] ?? []
        let dailyCodes = daily["weather_code"] as? [Int] ?? []

        let condition = Self.weatherDescription(code: weatherCode)
        let locationStr = locationName.map { " in \($0)" } ?? ""

        func formatTemp(_ celsius: Double) -> String {
            if useFahrenheit {
                let f = celsius * 9.0 / 5.0 + 32
                return "\(Int(round(f)))F"
            }
            return "\(Int(round(celsius)))C"
        }

        func formatWind(_ kmh: Double) -> String {
            if useFahrenheit {
                let mph = kmh * 0.621371
                return "\(Int(round(mph))) mph"
            }
            return "\(Int(round(kmh))) km/h"
        }

        var result = "Currently \(formatTemp(temp)) (feels like \(formatTemp(feelsLike))), \(condition)\(locationStr). Wind \(formatWind(windSpeed)), humidity \(humidity)%."

        if maxTemps.count >= 1 && minTemps.count >= 1 {
            result += " Today's high \(formatTemp(maxTemps[0])), low \(formatTemp(minTemps[0]))."
        }
        if maxTemps.count >= 2 && minTemps.count >= 2 && dailyCodes.count >= 2 {
            let tomorrowCondition = Self.weatherDescription(code: dailyCodes[1])
            result += " Tomorrow: \(tomorrowCondition), \(formatTemp(maxTemps[1]))/\(formatTemp(minTemps[1]))."
        }

        return result
    }

    /// Map WMO weather codes to human-readable descriptions
    static func weatherDescription(code: Int) -> String {
        switch code {
        case 0: return "clear sky"
        case 1: return "mainly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzle"
        case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"
        case 66, 67: return "freezing rain"
        case 71, 73, 75: return "snow"
        case 77: return "snow grains"
        case 80, 81, 82: return "rain showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"
        default: return "unknown conditions"
        }
    }
}

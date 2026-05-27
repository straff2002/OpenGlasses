import Foundation
import CoreLocation

/// Describes the user's current location: reverse-geocoded place context plus raw GPS coordinates.
/// Cheaper than `find_nearby` when the user just wants to know where they are.
final class WhereAmITool: NativeTool, @unchecked Sendable {
    let name = "where_am_i"
    let description = "Describe the user's current location with a reverse-geocoded place name and GPS coordinates."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let location = await MainActor.run(body: { locationService.currentLocation }) else {
            return "I don't have your location right now — make sure location access is enabled."
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let coords = String(format: "%.5f, %.5f", lat, lon)

        guard let place = await GeocodingHelper.reverseGeocode(location) else {
            return "GPS: \(coords). No address available."
        }

        if let address = place.fullAddress, !address.isEmpty {
            return "\(address) (GPS: \(coords))"
        }
        return "GPS: \(coords)"
    }
}

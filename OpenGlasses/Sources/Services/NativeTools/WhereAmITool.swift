import Foundation
import CoreLocation

/// Describes the user's current location: reverse-geocoded place context plus raw GPS coordinates.
/// Cheaper than `find_nearby` when the user just wants to know where they are.
final class WhereAmITool: NativeTool, @unchecked Sendable {
    let name = "where_am_i"
    let description = "Describe the user's current location with a reverse-geocoded place name and GPS coordinates. Also shows it as a map card on the wearer's Apple Watch; set show_on_watch when they asked to see it there."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "show_on_watch": [
                "type": "boolean",
                "description": "True when the wearer asked to see it on their watch."
            ]
        ] as [String: Any],
        "required": [] as [String]
    ]

    private let locationService: LocationService
    /// Plan GM P1a: the where-am-I card, handed to `GlanceSurfaceBus`.
    private let publishSurface: @MainActor (GlanceSurface, Bool) -> Void

    init(locationService: LocationService,
         publishSurface: @escaping @MainActor (GlanceSurface, Bool) -> Void = { surface, asked in
             AppStateProvider.shared?.glanceSurfaces.publish(surface, asked: asked)
         }) {
        self.locationService = locationService
        self.publishSurface = publishSurface
    }

    func execute(args: [String: Any]) async throws -> String {
        // A nil fix is usually transient (cold launch, backgrounded when-in-use permission) —
        // request a fresh one and wait briefly instead of giving up immediately.
        let service = locationService
        guard let location = await service.awaitFix(timeout: 2.0) else {
            return "I don't have your location right now — make sure location access is enabled."
        }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let coords = String(format: "%.5f, %.5f", lat, lon)

        let place = await GeocodingHelper.reverseGeocode(location)
        publish(location: location, place: place, asked: args["show_on_watch"] as? Bool ?? false)

        guard let place else {
            return "GPS: \(coords). No address available."
        }

        if let address = place.fullAddress, !address.isEmpty {
            return "\(address) (GPS: \(coords))"
        }
        return "GPS: \(coords)"
    }

    private func publish(location: CLLocation, place: GeocodingHelper.PlaceInfo?, asked: Bool) {
        // The street is the first part of MapKit's short address ("12 Queen Street, Auckland").
        let street = place?.shortAddress?
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)
        let surface = GlanceSurfaceBuilder.whereAmI(
            wearer: GlanceSurfaceBuilder.wearer(location),
            street: street?.isEmpty == false ? street : nil,
            locality: place?.cityName,
            mapAllowed: GlanceSurfacePolicy.mapAllowed(MedicalEgressGuard.currentMode()),
            now: Date())
        publishSurface(surface, asked)
    }
}

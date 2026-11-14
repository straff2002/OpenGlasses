import Foundation
import CoreLocation
import MapKit

/// Searches for nearby places (restaurants, cafes, pharmacies, etc.) using Apple's MapKit.
///
/// Results come closest first: Apple's search ranks by relevance, and "find a Thai restaurant" means
/// the one nearest the wearer, not the best-known one across town.
///
/// Plan GM P1a: the results also go to `GlanceSurfaceBus` as a `places` card, in the order they
/// are spoken; with `nearest: true` the tool answers "how far is that tower?" — the closest match,
/// its straight-line distance and direction — and publishes a `place` card instead.
final class LocationSearchTool: NativeTool, @unchecked Sendable {
    let name = "find_nearby"
    /// Plan LT §2: the query is model-written and goes to Apple Maps.
    var egressProfile: NativeEgressProfile? { .findNearby }
    let description = """
        Find nearby places like restaurants, cafes, gas stations, pharmacies, ATMs, etc. Uses the user's current location; \
        results come closest first, with their distances. Set nearest to true for "how far is <place>?" or "which way is <place>?": it answers with the closest match's \
        straight-line distance and direction, without starting directions. Results also show as a map card on the \
        wearer's Apple Watch; set show_on_watch when they asked to see them there.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "What to search for, e.g. 'coffee shop', 'pharmacy', 'gas station', 'Italian restaurant', 'Sky Tower'"
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum number of results to return. Defaults to 5."
            ],
            "nearest": [
                "type": "boolean",
                "description": "True to answer how far away the closest match is, in a straight line and which direction."
            ],
            "show_on_watch": [
                "type": "boolean",
                "description": "True when the wearer asked to see it on their watch."
            ]
        ],
        "required": ["query"]
    ]

    /// Everything live, so a test runs the tool against stub map items.
    struct Seams {
        var currentLocation: () async -> CLLocation?
        var search: (MKLocalSearch.Request) async throws -> [MKMapItem] = { request in
            try await MKLocalSearch(request: request).start().mapItems
        }
        var publishSurface: @MainActor (GlanceSurface, Bool) -> Void = { surface, asked in
            AppStateProvider.shared?.glanceSurfaces.publish(surface, asked: asked)
        }
        var mapAllowed: () -> Bool = { GlanceSurfacePolicy.mapAllowed(MedicalEgressGuard.currentMode()) }
        var metric: () -> Bool = { ParkingTool.prefersMetric }
        var now: () -> Date = Date.init
    }

    private let seams: Seams

    init(seams: Seams) {
        self.seams = seams
    }

    convenience init(locationService: LocationService) {
        self.init(seams: Seams(currentLocation: { [weak locationService] in
            await MainActor.run { locationService?.currentLocation }
        }))
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "No search query provided."
        }

        let limit = (args["limit"] as? Int) ?? 5
        let nearest = args["nearest"] as? Bool ?? false
        let asked = args["show_on_watch"] as? Bool ?? false

        // Get current location
        guard let location = await seams.currentLocation() else {
            return "I don't have your current location. Make sure location services are enabled."
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 5000,
            longitudinalMeters: 5000
        )

        do {
            let found = try await seams.search(request)
            if nearest { return distanceTo(query: query, items: found, from: location, asked: asked) }

            let items = Array(Self.closestFirst(found, from: location).prefix(limit))

            guard !items.isEmpty else {
                return "No results found for '\(query)' near your location."
            }

            var results: [String] = []
            for item in items {
                let name = item.name ?? "Unknown"
                var detail = name

                // Distance & address
                let (itemLoc, address) = GeocodingHelper.locationAndAddress(from: item)
                if let itemLoc {
                    let distance = location.distance(from: itemLoc)
                    if distance < 1000 {
                        detail += String(format: " (%.0f m away)", distance)
                    } else {
                        detail += String(format: " (%.1f km away)", distance / 1000)
                    }
                }
                if let address {
                    detail += " at \(address)"
                }

                results.append(detail)
            }

            publishPlaces(query: query, items: items, from: location, asked: asked)
            return "Found \(items.count) result\(items.count == 1 ? "" : "s") for '\(query)': \(results.joined(separator: ". "))."
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    /// `items` by straight-line distance from `location`, nearest first; equal distances keep
    /// the search's order.
    nonisolated static func closestFirst(_ items: [MKMapItem], from location: CLLocation) -> [MKMapItem] {
        items.enumerated()
            .map { (index: $0.offset, item: $0.element, meters: location.distance(from: $0.element.location)) }
            .sorted { ($0.meters, $0.index) < ($1.meters, $1.index) }
            .map(\.item)
    }

    // MARK: - Surfaces

    private func publishPlaces(query: String, items: [MKMapItem], from location: CLLocation, asked: Bool) {
        let surface = GlanceSurfaceBuilder.places(
            query: query,
            candidates: GlanceSurfaceBuilder.candidates(from: items, wearer: location),
            wearer: GlanceSurfaceBuilder.wearer(location),
            mapAllowed: seams.mapAllowed(), now: seams.now())
        seams.publishSurface(surface, asked)
    }

    /// "How far is that tower?" — the closest of the matches, as a straight line. The spoken
    /// answer names the place it resolved, so a wrong match is audible as well as visible.
    private func distanceTo(query: String, items: [MKMapItem], from location: CLLocation, asked: Bool) -> String {
        guard let closest = items.min(by: { location.distance(from: $0.location) < location.distance(from: $1.location) }) else {
            return "I couldn't find \(query) near you."
        }
        let name = closest.name ?? query
        let surface = GlanceSurfaceBuilder.place(
            name: name,
            subtitle: GeocodingHelper.locationAndAddress(from: closest).address,
            coordinate: GlanceSurfaceBuilder.point(closest.location.coordinate),
            wearer: GlanceSurfaceBuilder.wearer(location),
            mapAllowed: seams.mapAllowed(), now: seams.now())
        seams.publishSurface(surface, asked)

        guard case .place(let card) = surface.kind else { return "\(name) is nearby." }
        let distance = DistanceFormatter.spoken(Int(card.straightLineMeters.rounded()), metric: seams.metric())
        let direction = GlanceGeometry.compassPoint(forBearing: card.bearingDegrees).words
        return "\(name) is \(distance) to the \(direction) of you, in a straight line."
    }
}

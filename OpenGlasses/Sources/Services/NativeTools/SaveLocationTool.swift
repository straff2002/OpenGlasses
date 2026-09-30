import Foundation
import CoreLocation

/// Saves the user's current GPS location with a label, so they can find their way back later —
/// "bookmark this spot", "save this location". Parking has its own tool (`parking`, Plan GH), which
/// knows about levels and spaces, so this one no longer claims it.
final class SaveLocationTool: NativeTool, @unchecked Sendable {
    let name = "save_location"
    let description = "Save the user's current location with a label — marking a spot to return to, or bookmarking a place they're at (a hotel, a meeting point, a great restaurant). For where the user parked their car, use the parking tool instead."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": [
                "type": "string",
                "description": "A label for this location, e.g. 'hotel', 'that great restaurant', 'meeting point'"
            ]
        ],
        "required": ["label"]
    ]

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    private static let storageKey = "saved_locations"
    private static let maxLocations = 50

    private struct SavedLocation: Codable {
        let label: String
        let latitude: Double
        let longitude: Double
        let address: String?
        let timestamp: Date
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let label = args["label"] as? String, !label.isEmpty else {
            return "No label provided. Tell me what to call this spot, like 'hotel' or 'meeting point'."
        }

        guard let location = await MainActor.run(body: { locationService.currentLocation }) else {
            return "I don't have your current location. Make sure location services are enabled."
        }

        // Reverse geocode for a human-readable address
        let address = await reverseGeocode(location)

        let saved = SavedLocation(
            label: label,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            address: address,
            timestamp: Date()
        )

        var locations = loadLocations()
        locations.append(saved)
        if locations.count > Self.maxLocations {
            locations = Array(locations.suffix(Self.maxLocations))
        }
        saveLocations(locations)

        var response = "Saved '\(label)' at your current location"
        if let address {
            response += " (\(address))"
        }
        response += ". You can ask me to navigate back here anytime."
        return response
    }

    private func reverseGeocode(_ location: CLLocation) async -> String? {
        guard let place = await GeocodingHelper.reverseGeocode(location) else { return nil }
        if let street = place.streetAddress, let city = place.locality {
            return "\(street), \(city)"
        }
        return place.streetAddress ?? place.fullAddress
    }

    private func loadLocations() -> [SavedLocation] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let locations = try? JSONDecoder().decode([SavedLocation].self, from: data) else {
            return []
        }
        return locations
    }

    private func saveLocations(_ locations: [SavedLocation]) {
        if let data = try? JSONEncoder().encode(locations) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// Lists saved locations and can provide directions back to any of them.
final class ListSavedLocationsTool: NativeTool, @unchecked Sendable {
    let name = "list_saved_locations"
    let description = "List all saved locations, or find a specific one by name. Can show distance from current position."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "search": [
                "type": "string",
                "description": "Optional search term to filter locations, e.g. 'car' or 'hotel'"
            ]
        ],
        "required": [] as [String]
    ]

    private let locationService: LocationService
    private static let storageKey = "saved_locations"

    private struct SavedLocation: Codable {
        let label: String
        let latitude: Double
        let longitude: Double
        let address: String?
        let timestamp: Date
    }

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(args: [String: Any]) async throws -> String {
        let search = args["search"] as? String

        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let allLocations = try? JSONDecoder().decode([SavedLocation].self, from: data),
              !allLocations.isEmpty else {
            return "You don't have any saved locations. Say 'remember this spot' or 'save this location as the hotel' to save one."
        }

        let locations: [SavedLocation]
        if let search, !search.isEmpty {
            let term = search.lowercased()
            locations = allLocations.filter { $0.label.lowercased().contains(term) }
            if locations.isEmpty {
                let allLabels = allLocations.map { $0.label }.joined(separator: ", ")
                return "No saved location matching '\(search)'. Your saved spots: \(allLabels)."
            }
        } else {
            locations = allLocations
        }

        let currentLocation = await MainActor.run(body: { locationService.currentLocation })
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"

        var results: [String] = []
        for loc in locations.suffix(10) {
            var entry = "'\(loc.label)'"
            if let addr = loc.address {
                entry += " at \(addr)"
            }

            // Distance from current position
            if let current = currentLocation {
                let saved = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                let dist = current.distance(from: saved)
                if dist < 1000 {
                    entry += String(format: " (%.0f m away)", dist)
                } else {
                    entry += String(format: " (%.1f km away)", dist / 1000)
                }
            }

            entry += " saved \(formatter.string(from: loc.timestamp))"
            results.append(entry)
        }

        var response = "Saved locations: \(results.joined(separator: ". "))."
        if locations.count > 10 {
            response += " Plus \(locations.count - 10) more."
        }
        response += " Say 'navigate to [label]' to get directions back to any of these."
        return response
    }
}

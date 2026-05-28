import Foundation
import CoreLocation

/// Reports aircraft currently overhead using the free public ADS-B feed at opendata.adsb.fi
/// (no API key). Uses the device's current location and returns an imperial-units summary.
@MainActor
final class AircraftOverheadTool: NativeTool {
    let name = "aircraft_overhead"
    let description = """
    Report aircraft flying near the user's current location using live ADS-B data. Use for \
    "what's flying overhead?", "any planes nearby?", "what aircraft is above me?". Returns a summary \
    of the nearest aircraft with distance, altitude, speed, and heading. Param: radius_miles (1–200, default 25).
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "radius_miles": [
                "type": "integer",
                "description": "Search radius in miles (1–200). Default 25."
            ]
        ],
        "required": [] as [String]
    ]

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let location = locationService.currentLocation else {
            return "I don't have your location yet. Make sure location access is enabled and try again."
        }
        let radiusMiles = min(max((args["radius_miles"] as? Int) ?? 25, 1), 200)
        let radiusNM = Int((Double(radiusMiles) / 1.15078).rounded()) // miles → nautical miles

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "https://opendata.adsb.fi/api/v2/lat/\(String(format: "%.4f", lat))/lon/\(String(format: "%.4f", lon))/dist/\(radiusNM)"
        guard let url = URL(string: urlString) else { return "Could not build the aircraft query." }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("OpenGlasses", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let aircraft = json["ac"] as? [[String: Any]] else {
                return "Couldn't reach the aircraft feed right now. Try again in a moment."
            }
            return summarize(aircraft, origin: location, radiusMiles: radiusMiles)
        } catch {
            return "Aircraft lookup failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Formatting

    private func summarize(_ aircraft: [[String: Any]], origin: CLLocation, radiusMiles: Int) -> String {
        // Build sortable entries with distance from the user.
        var entries: [(distance: Double, line: String)] = []
        for ac in aircraft {
            guard let acLat = doubleValue(ac["lat"]), let acLon = doubleValue(ac["lon"]) else { continue }
            let acLocation = CLLocation(latitude: acLat, longitude: acLon)
            let distanceMiles = origin.distance(from: acLocation) / 1609.34

            let callsign = (ac["flight"] as? String)?.trimmingCharacters(in: .whitespaces)
            let id = callsign?.isEmpty == false ? callsign! : (ac["hex"] as? String ?? "unknown")
            let typeDesc = ac["t"] as? String
            let bearing = Self.bearing(from: origin.coordinate, to: acLocation.coordinate)
            let compass = Self.compassPoint(bearing)

            let altitude = altitudeString(ac["alt_baro"])
            let speed = doubleValue(ac["gs"]).map { "\(Int($0.rounded())) kts" }
            let track = doubleValue(ac["track"]).map { "heading \(Int($0.rounded()))°" }
            let vert = verticalTrend(ac["baro_rate"])

            var parts = ["\(id)"]
            if let typeDesc, !typeDesc.isEmpty { parts[0] += " (\(typeDesc))" }
            parts.append("\(String(format: "%.0f", distanceMiles)) mi \(compass)")
            if let altitude { parts.append(altitude) }
            if let speed { parts.append(speed) }
            if let track { parts.append(track) }
            if let vert { parts.append(vert) }

            entries.append((distanceMiles, "- " + parts.joined(separator: ", ")))
        }

        guard !entries.isEmpty else {
            return "No aircraft detected within \(radiusMiles) miles right now."
        }
        entries.sort { $0.distance < $1.distance }
        let top = entries.prefix(5)
        let header = "\(entries.count) aircraft within \(radiusMiles) miles:"
        return ([header] + top.map(\.line)).joined(separator: "\n")
    }

    private func altitudeString(_ value: Any?) -> String? {
        if let s = value as? String, s.lowercased() == "ground" { return "on ground" }
        guard let feet = doubleValue(value) else { return nil }
        // Flight level above 18,000 ft, otherwise raw feet.
        if feet >= 18000 { return "FL\(Int((feet / 100).rounded()))" }
        return "\(Int(feet.rounded())) ft"
    }

    private func verticalTrend(_ value: Any?) -> String? {
        guard let rate = doubleValue(value) else { return nil }
        if rate > 100 { return "climbing" }
        if rate < -100 { return "descending" }
        return "level"
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    nonisolated static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    nonisolated static func compassPoint(_ bearing: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((bearing / 45).rounded()) % 8
        return points[index]
    }
}

import Foundation

/// A defibrillator location.
struct AED: Equatable {
    let latitude: Double
    let longitude: Double
    let name: String?
}

/// Finds the nearest public AED (automated external defibrillator) via OpenStreetMap's **Overpass** API
/// (`emergency=defibrillator`), for the First-Aid / Emergency Assist flow. The query construction,
/// JSON parsing, and nearest-by-distance selection are pure + testable; the live HTTP call is an
/// injected fetcher (defaults to URLSession).
struct AEDFinder {

    /// Fetches the bytes for an Overpass request URL. Injected so the finder is testable without network.
    typealias Fetcher = (_ url: URL) async throws -> Data

    let fetch: Fetcher

    init(fetch: @escaping Fetcher = AEDFinder.liveFetch) {
        self.fetch = fetch
    }

    /// Build the Overpass API URL for defibrillators within `radiusMeters` of a coordinate.
    static func overpassURL(latitude: Double, longitude: Double, radiusMeters: Int) -> URL {
        let query = "[out:json][timeout:10];node[emergency=defibrillator](around:\(radiusMeters),\(latitude),\(longitude));out;"
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        // swiftlint:disable:next force_unwrapping — fixed host + percent-escaped query.
        return URL(string: "https://overpass-api.de/api/interpreter?data=\(escaped)")!
    }

    /// Parse an Overpass JSON response into AEDs.
    static func parse(_ data: Data) throws -> [AED] {
        struct Response: Decodable {
            struct Element: Decodable {
                let lat: Double?
                let lon: Double?
                let tags: [String: String]?
            }
            let elements: [Element]
        }
        return try JSONDecoder().decode(Response.self, from: data).elements.compactMap { element in
            guard let lat = element.lat, let lon = element.lon else { return nil }
            return AED(latitude: lat, longitude: lon, name: element.tags?["name"])
        }
    }

    /// Great-circle distance in metres between two coordinates (haversine).
    static func distanceMeters(fromLat lat1: Double, lon lon1: Double, toLat lat2: Double, lon lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// The AED closest to a coordinate, or nil if the list is empty.
    static func nearest(_ aeds: [AED], toLat lat: Double, lon: Double) -> AED? {
        aeds.min { a, b in
            distanceMeters(fromLat: lat, lon: lon, toLat: a.latitude, lon: a.longitude)
                < distanceMeters(fromLat: lat, lon: lon, toLat: b.latitude, lon: b.longitude)
        }
    }

    /// Query Overpass and return the nearest AED within `radiusMeters` (nil if none found).
    func nearestAED(latitude: Double, longitude: Double, radiusMeters: Int = 2000) async throws -> AED? {
        // The wearer's coordinates go to a public directory. In local-only mode the caller falls
        // back to its offline guidance rather than pinning the wearer on a public map.
        try MedicalEgressGuard.check(.aedDirectory)
        let data = try await fetch(Self.overpassURL(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters))
        return Self.nearest(try Self.parse(data), toLat: latitude, lon: longitude)
    }

    static let liveFetch: Fetcher = { url in
        try await URLSession.shared.data(from: url).0
    }
}

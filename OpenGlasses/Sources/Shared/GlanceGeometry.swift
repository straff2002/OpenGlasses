import Foundation

/// Plan GM P0 — the pure geometry every glance surface needs: straight-line distance and initial
/// bearing between two points, the compass word for a bearing, and the map region that frames a
/// set of points with room for the card drawn over it. Foundation only (phone and watch).
enum GlanceGeometry {

    static let earthRadius: Double = 6_371_000

    /// Great-circle distance in metres (haversine).
    static func distanceMeters(_ a: GlancePoint, _ b: GlancePoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle bearing from `a` to `b`, degrees clockwise from true north in
    /// `0..<360`. Identical points give 0.
    static func initialBearingDegrees(from a: GlancePoint, to b: GlancePoint) -> Double {
        guard a != b else { return 0 }
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        let normalised = (degrees + 360).truncatingRemainder(dividingBy: 360)
        return normalised == 360 ? 0 : normalised
    }

    /// The eight compass points.
    enum CompassPoint: String, CaseIterable, Sendable {
        case north, northEast, east, southEast, south, southWest, west, northWest

        /// "north-east", for a VoiceOver summary or a caption.
        var words: String {
            switch self {
            case .north: return "north"
            case .northEast: return "north-east"
            case .east: return "east"
            case .southEast: return "south-east"
            case .south: return "south"
            case .southWest: return "south-west"
            case .west: return "west"
            case .northWest: return "north-west"
            }
        }
    }

    static func compassPoint(forBearing degrees: Double) -> CompassPoint {
        let normalised = ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalised / 45).rounded()) % 8
        return CompassPoint.allCases[index]
    }

    // MARK: - Framing

    /// A map region in degrees. `center.longitude` is in `-180...180`; the span never crosses
    /// 360° and a region that straddles the antimeridian keeps a small span (it does not wrap the
    /// other way round the world).
    struct Region: Equatable, Sendable {
        let centerLatitude: Double
        let centerLongitude: Double
        let latitudeDelta: Double
        let longitudeDelta: Double
    }

    /// The region that frames `points`, grown by `padding` (a fraction of the span on each side,
    /// so 0.25 adds a quarter top and bottom) and by `bottomInset` (an extra fraction of the span
    /// below, for the card drawn over the foot of the map). A single point, or points closer
    /// together than `minimumSpanMeters`, frame `minimumSpanMeters` around their centre.
    /// Nil for no points.
    static func region(framing points: [GlancePoint],
                       padding: Double = 0.25,
                       bottomInset: Double = 0,
                       minimumSpanMeters: Double = 300) -> Region? {
        guard !points.isEmpty else { return nil }

        let lats = points.map(\.latitude)
        var lons = points.map(\.longitude)
        // Across the antimeridian the naive span is nearly 360°; shifting the western points by
        // a full turn gives the short way round.
        if let minLon = lons.min(), let maxLon = lons.max(), maxLon - minLon > 180 {
            lons = lons.map { $0 < 0 ? $0 + 360 : $0 }
        }
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!

        var latSpan = maxLat - minLat
        var lonSpan = maxLon - minLon
        var centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        // Minimum span, in degrees at this latitude.
        let metersPerDegreeLat = earthRadius * .pi / 180
        let cosLat = max(0.01, cos(centerLat * .pi / 180))
        let minLatSpan = minimumSpanMeters / metersPerDegreeLat
        let minLonSpan = minimumSpanMeters / (metersPerDegreeLat * cosLat)
        latSpan = max(latSpan, minLatSpan)
        lonSpan = max(lonSpan, minLonSpan)

        let paddedLat = latSpan * (1 + 2 * padding + bottomInset)
        let paddedLon = lonSpan * (1 + 2 * padding)
        // The inset is added below, so the centre moves down by half of it.
        centerLat -= latSpan * bottomInset / 2

        var normalisedLon = centerLon.truncatingRemainder(dividingBy: 360)
        if normalisedLon > 180 { normalisedLon -= 360 }
        if normalisedLon < -180 { normalisedLon += 360 }

        return Region(centerLatitude: min(90, max(-90, centerLat)),
                      centerLongitude: normalisedLon,
                      latitudeDelta: min(180, paddedLat),
                      longitudeDelta: min(360, paddedLon))
    }
}

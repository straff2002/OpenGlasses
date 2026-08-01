import Foundation

/// Plan CA — turn-by-turn walking navigation: the deterministic route model. No MapKit types
/// here; `WalkingRouteService` maps `MKRoute` into this and everything downstream (phrasing,
/// progress tracking) is pure and headless-testable.

/// A latitude/longitude pair. `CLLocationCoordinate2D` isn't Codable and drags CoreLocation
/// into the pure core; this is the boundary type.
struct RoutePoint: Codable, Equatable {
    var lat: Double
    var lon: Double
}

/// Maneuver classes the HUD can draw an arrow for. MapKit exposes only instruction *text* on
/// `MKRoute.Step` (no maneuver field), so this is keyword-parsed from the English instruction —
/// unparseable or non-English instructions degrade to `.continueStraight` (text still shown).
enum Maneuver: String, Codable, CaseIterable {
    case depart, turnLeft, turnRight, slightLeft, slightRight
    case uTurn, roundabout, continueStraight, arrive

    static func parse(instruction: String) -> Maneuver {
        let text = instruction.lowercased()
        if text.contains("arrive") || text.contains("destination") { return .arrive }
        if text.contains("u-turn") || text.contains("u turn") { return .uTurn }
        if text.contains("roundabout") || text.contains("rotary") { return .roundabout }
        if text.contains("slight left") || text.contains("bear left") || text.contains("keep left") { return .slightLeft }
        if text.contains("slight right") || text.contains("bear right") || text.contains("keep right") { return .slightRight }
        if text.contains("turn left") || text.hasPrefix("left ") { return .turnLeft }
        if text.contains("turn right") || text.hasPrefix("right ") { return .turnRight }
        if text.contains("depart") || text.hasPrefix("head ") || text.hasPrefix("walk ") { return .depart }
        return .continueStraight
    }

    /// The HUD card's arrow glyph (plain text — the in-lens surface is a token DSL, not a map).
    var arrow: String {
        switch self {
        case .depart: return "▲"
        case .turnLeft: return "←"
        case .turnRight: return "→"
        case .slightLeft: return "↖"
        case .slightRight: return "↗"
        case .uTurn: return "⤴"
        case .roundabout: return "↻"
        case .continueStraight: return "↑"
        case .arrive: return "⚑"
        }
    }

    /// Spoken verb phrase, street appended by the phraser when known.
    var verb: String {
        switch self {
        case .depart: return "head out"
        case .turnLeft: return "turn left"
        case .turnRight: return "turn right"
        case .slightLeft: return "bear left"
        case .slightRight: return "bear right"
        case .uTurn: return "make a U-turn"
        case .roundabout: return "take the roundabout"
        case .continueStraight: return "continue straight"
        case .arrive: return "arrive at your destination"
        }
    }
}

/// One maneuver of a walking route. `maneuverPoint` is where the instruction executes;
/// `inboundLeg` is the path walked to *reach* it (off-route checks measure against this), and
/// `inboundDistance` its length in meters.
struct RouteStep: Codable, Equatable {
    let instruction: String
    let maneuver: Maneuver
    let streetName: String?
    let maneuverPoint: RoutePoint
    let inboundLeg: [RoutePoint]
    let inboundDistance: Double
}

// MARK: - Pure geometry

/// Meters-scale geo math for the tracker. Haversine for point distance; a local
/// equirectangular projection for point-to-leg distance (exact enough at walking-leg scale).
enum RouteGeometry {

    static let earthRadius: Double = 6_371_000

    static func metersDistance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Minimum distance from `point` to the polyline `leg` (meters). Empty leg → infinity.
    static func distanceToLeg(_ point: RoutePoint, leg: [RoutePoint]) -> Double {
        guard let first = leg.first else { return .infinity }
        guard leg.count > 1 else { return metersDistance(point, first) }

        // Project into a local tangent plane centered on the query point.
        let cosLat = cos(point.lat * .pi / 180)
        func toXY(_ p: RoutePoint) -> (x: Double, y: Double) {
            let x = (p.lon - point.lon) * .pi / 180 * earthRadius * cosLat
            let y = (p.lat - point.lat) * .pi / 180 * earthRadius
            return (x, y)
        }

        var best = Double.infinity
        for i in 0..<(leg.count - 1) {
            let a = toXY(leg[i])
            let b = toXY(leg[i + 1])
            let abx = b.x - a.x, aby = b.y - a.y
            let lengthSquared = abx * abx + aby * aby
            let t: Double
            if lengthSquared == 0 {
                t = 0
            } else {
                // Query point is the origin in this frame.
                t = max(0, min(1, (-a.x * abx - a.y * aby) / lengthSquared))
            }
            let cx = a.x + t * abx, cy = a.y + t * aby
            best = min(best, (cx * cx + cy * cy).squareRoot())
        }
        return best
    }
}

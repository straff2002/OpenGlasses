import Foundation

/// Plan GM P0 — the shared surface model: a spatial or list answer as plain values, drawn by the
/// watch (map cards on the wrist) and by the phone's conversation map (Plan HH) from the same
/// payload, so the two never disagree about a name or a distance.
///
/// Foundation only, compiled into the phone and the watch targets (`project.watch.yml`). No
/// MapKit or CoreLocation types: the phone-only `GlanceSurfaceBuilder` converts into these.

// MARK: - Wire names

/// The names both ends of the watch link use for surfaces, written once.
enum GlanceWire {
    /// The application-context key holding the encoded `GlanceSurfaceSet`.
    static let contextKey = "surfaces"
    /// Watch → phone: **Go** on a card.
    static let startGuidanceCommand = "startGuidance"
    static let surfaceIdKey = "surface_id"
    static let placeIdKey = "place_id"
}

// MARK: - Points and fixes

/// A latitude/longitude stored as `Int32` in units of 1e-7 degrees (about 1 cm), so a 300-point
/// route line packs into 2.4 KB of `Data` (`GlancePolyline`).
struct GlancePoint: Codable, Equatable, Hashable, Sendable {
    static let scale: Double = 10_000_000

    let latE7: Int32
    let lonE7: Int32

    init(latitude: Double, longitude: Double) {
        let lat = min(90, max(-90, latitude))
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        latE7 = Int32((lat * Self.scale).rounded())
        lonE7 = Int32((lon * Self.scale).rounded())
    }

    var latitude: Double { Double(latE7) / Self.scale }
    var longitude: Double { Double(lonE7) / Self.scale }
}

/// Where the wearer was, according to the **phone** — every card carries the phone's fix, so the
/// distance on the wrist is the distance that was spoken and the watch needs no location
/// permission.
struct WearerFix: Codable, Equatable, Sendable {
    let coordinate: GlancePoint
    let fixAt: Date
    /// Metres; negative when the fix has no valid accuracy.
    let horizontalAccuracy: Double
}

/// A route line as packed little-endian `Int32` pairs, encoded as one `Data` value rather than an
/// array of dictionaries (a property list of 300 dictionaries is roughly ten times larger).
struct GlancePolyline: Codable, Equatable, Sendable {
    let points: [GlancePoint]

    init(points: [GlancePoint]) { self.points = points }

    init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard data.count % 8 == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Polyline bytes are not whole points"))
        }
        var points: [GlancePoint] = []
        points.reserveCapacity(data.count / 8)
        let bytes = [UInt8](data)
        func int32(at offset: Int) -> Int32 {
            var raw: UInt32 = 0
            for i in 0..<4 { raw |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
            return Int32(bitPattern: raw)
        }
        var offset = 0
        while offset < bytes.count {
            let lat = int32(at: offset), lon = int32(at: offset + 4)
            points.append(GlancePoint(latE7: lat, lonE7: lon))
            offset += 8
        }
        self.points = points
    }

    func encode(to encoder: Encoder) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(points.count * 8)
        func append(_ value: Int32) {
            let raw = UInt32(bitPattern: value)
            for i in 0..<4 { bytes.append(UInt8((raw >> (8 * UInt32(i))) & 0xFF)) }
        }
        for point in points {
            append(point.latE7)
            append(point.lonE7)
        }
        var container = encoder.singleValueContainer()
        try container.encode(Data(bytes))
    }
}

extension GlancePoint {
    /// Raw storage, for the packed polyline. Not range-normalised: the value is already stored.
    fileprivate init(latE7: Int32, lonE7: Int32) {
        self.latE7 = latE7
        self.lonE7 = lonE7
    }
}

// MARK: - Cards

/// Walking, cycling or driving. Plan GL's `TravelProfile` raw values; walking until GL lands.
enum GlanceTravelMode: String, Codable, Equatable, Sendable, CaseIterable {
    case walking, cycling, driving
}

/// A time to get somewhere by one mode.
struct GlanceETA: Codable, Equatable, Sendable {
    let mode: GlanceTravelMode
    let seconds: Int
}

/// "How far is that tower?" — one place, with the wearer when there is a fix.
struct PlaceCard: Codable, Equatable, Sendable {
    let name: String
    /// Street / suburb.
    let subtitle: String?
    let coordinate: GlancePoint
    let wearer: WearerFix?
    /// From the wearer; 0 when there is no wearer fix.
    let straightLineMeters: Double
    /// Initial bearing from the wearer, degrees clockwise from north; 0 with no wearer fix.
    let bearingDegrees: Double
    let routeMeters: Double?
    let etas: [GlanceETA]

    /// The distance a card shows: the route distance when there is one, else the straight line.
    var shownMeters: Double { routeMeters ?? straightLineMeters }
    /// True when `shownMeters` is a straight line and the card must say so.
    var isStraightLine: Bool { routeMeters == nil }

    /// A place card made on the watch from a tapped `places` row and the shared wearer fix — no
    /// round trip to the phone. The distance is the row's own (the figure the answer spoke); the
    /// bearing is worked out from the fix.
    static func from(row: PlaceRow, wearer: WearerFix?) -> PlaceCard {
        let bearing = wearer.map { GlanceGeometry.initialBearingDegrees(from: $0.coordinate, to: row.coordinate) } ?? 0
        return PlaceCard(name: row.name, subtitle: row.category, coordinate: row.coordinate,
                         wearer: wearer, straightLineMeters: row.meters, bearingDegrees: bearing,
                         routeMeters: nil, etas: [])
    }
}

/// "Where am I?"
struct WhereCard: Codable, Equatable, Sendable {
    let wearer: WearerFix
    let street: String?
    let locality: String?
}

/// One result of a nearby search, in the order it was spoken.
struct PlaceRow: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: String?
    /// Straight-line metres from the wearer when the search ran.
    let meters: Double
    let coordinate: GlancePoint
}

/// "Find a pharmacy" — up to `maxRows` results.
struct PlacesCard: Codable, Equatable, Sendable {
    static let maxRows = 8

    let query: String
    let rows: [PlaceRow]
    let wearer: WearerFix?
    /// Rows the codec dropped to fit the byte budget (stated, never silent).
    var droppedRows: Int = 0
}

/// The next maneuver (or the one after it) on a route.
struct GlanceManeuver: Codable, Equatable, Sendable {
    /// The phone's `Maneuver` raw value (`turnLeft`, `arrive`, …).
    let maneuver: String
    let street: String?
    /// Banded metres to it, as spoken.
    let bandedMeters: Int
}

/// The live route — the whole line, sent on start, reroute and mode switch only; `RouteDelta`
/// carries the movement between.
struct RouteSnapshot: Codable, Equatable, Sendable {
    static let maxPoints = 300

    let polyline: GlancePolyline
    let destinationName: String
    let destination: GlancePoint
    let mode: GlanceTravelMode
    let activeStepIndex: Int
    let next: GlanceManeuver?
    let then: GlanceManeuver?
    let remainingMeters: Double
    let arrivalAt: Date?
    let wearer: WearerFix?
}

/// A list the wearer can glance at (and, in a later phase, tick off).
struct ListCard: Codable, Equatable, Sendable {
    static let maxItems = 30

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let text: String
        let checked: Bool
    }

    let title: String?
    let items: [Item]
    /// Where the list came from (an answer, an add-on step).
    let origin: String
}

/// An image card. The JPEG travels by `transferFile`, never inside the context.
struct ImageCard: Codable, Equatable, Sendable {
    let caption: String
    let source: String
    /// The transferred file's name on the receiving side.
    let fileName: String
}

// MARK: - The surface

/// One thing shown on a glance surface.
struct GlanceSurface: Codable, Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case place(PlaceCard)
        case whereAmI(WhereCard)
        case places(PlacesCard)
        case route(RouteSnapshot)
        case list(ListCard)
        case image(ImageCard)

        /// The stable wire tag.
        var tag: String {
            switch self {
            case .place: return "place"
            case .whereAmI: return "whereAmI"
            case .places: return "places"
            case .route: return "route"
            case .list: return "list"
            case .image: return "image"
            }
        }

        /// Place, where-am-I, nearby and route: the answers that carry a location.
        var isSpatial: Bool {
            switch self {
            case .place, .whereAmI, .places, .route: return true
            case .list, .image: return false
            }
        }
    }

    let id: String
    let createdAt: Date
    /// Nil: until replaced (a route lasts until guidance ends).
    let expiresAt: Date?
    /// False under Medical Local Only: draw the text card, never a map, because tiles are fetched
    /// from Apple around the wearer's position.
    var mapAllowed: Bool
    var kind: Kind

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// The wearer's fix the card carries, if any.
    var wearer: WearerFix? {
        switch kind {
        case .place(let card): return card.wearer
        case .whereAmI(let card): return card.wearer
        case .places(let card): return card.wearer
        case .route(let card): return card.wearer
        case .list, .image: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, expiresAt, mapAllowed, type
        case place, whereAmI, places, route, list, image
    }

    init(id: String, createdAt: Date, expiresAt: Date?, mapAllowed: Bool, kind: Kind) {
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.mapAllowed = mapAllowed
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        mapAllowed = try c.decode(Bool.self, forKey: .mapAllowed)
        switch try c.decode(String.self, forKey: .type) {
        case "place": kind = .place(try c.decode(PlaceCard.self, forKey: .place))
        case "whereAmI": kind = .whereAmI(try c.decode(WhereCard.self, forKey: .whereAmI))
        case "places": kind = .places(try c.decode(PlacesCard.self, forKey: .places))
        case "route": kind = .route(try c.decode(RouteSnapshot.self, forKey: .route))
        case "list": kind = .list(try c.decode(ListCard.self, forKey: .list))
        case "image": kind = .image(try c.decode(ImageCard.self, forKey: .image))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Unknown surface kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encode(mapAllowed, forKey: .mapAllowed)
        try c.encode(kind.tag, forKey: .type)
        switch kind {
        case .place(let card): try c.encode(card, forKey: .place)
        case .whereAmI(let card): try c.encode(card, forKey: .whereAmI)
        case .places(let card): try c.encode(card, forKey: .places)
        case .route(let card): try c.encode(card, forKey: .route)
        case .list(let card): try c.encode(card, forKey: .list)
        case .image(let card): try c.encode(card, forKey: .image)
        }
    }
}

/// What a surface consumer holds at once: the latest card, and the live route if guidance runs.
/// The watch receives this as the `surfaces` value of the application context (latest wins).
struct GlanceSurfaceSet: Codable, Equatable, Sendable {
    var current: GlanceSurface?
    var route: GlanceSurface?
    /// One tap on arrival: the wearer asked to see it on the watch. Automatic cards are silent.
    var playsTap: Bool = false
    /// Distances in metres and kilometres (else feet and miles) — the phone's units setting.
    var usesMetric: Bool = true

    var isEmpty: Bool { current == nil && route == nil }

    /// The same set without anything expired at `now`.
    func live(at now: Date) -> GlanceSurfaceSet {
        var copy = self
        if copy.current?.isExpired(at: now) == true { copy.current = nil }
        if copy.route?.isExpired(at: now) == true { copy.route = nil }
        return copy
    }
}

// MARK: - Route delta

/// The movement between full route snapshots: small, latest-wins, safe to drop — the next one
/// supersedes it and the design never depends on any one delta arriving.
struct RouteDelta: Codable, Equatable, Sendable {
    enum Cue: String, Codable, Equatable, Sendable {
        case approach, imminent, arrived, rerouting
    }

    let surfaceId: String
    let wearer: WearerFix?
    let activeStepIndex: Int
    let bandedMetersToManeuver: Int
    let remainingMeters: Double
    let cue: Cue?
    let sentAt: Date

    /// Whether this delta says something the previous one did not: a banded-distance change, a
    /// step change or a cue. Only such a delta is worth sending (and at most once per
    /// `minimumInterval`, unless it carries a cue).
    func isMeaningfulChange(from previous: RouteDelta?) -> Bool {
        guard let previous, previous.surfaceId == surfaceId else { return true }
        if cue != nil { return true }
        return activeStepIndex != previous.activeStepIndex
            || bandedMetersToManeuver != previous.bandedMetersToManeuver
    }

    static let minimumInterval: TimeInterval = 2

    /// Send now? A cue always goes; anything else needs a meaningful change and 2 s since the last.
    func shouldSend(after previous: RouteDelta?) -> Bool {
        guard isMeaningfulChange(from: previous) else { return false }
        guard let previous, previous.surfaceId == surfaceId, cue == nil else { return true }
        return sentAt.timeIntervalSince(previous.sentAt) >= Self.minimumInterval
    }

    /// Whether `snapshot` is the route this delta moves along.
    func applies(to snapshot: GlanceSurface) -> Bool {
        guard case .route = snapshot.kind else { return false }
        return snapshot.id == surfaceId
    }
}

// MARK: - Wearer dot freshness

/// How old the wearer's dot is, by the plan's table. The dot never moves by dead reckoning; a
/// stale dot says it is stale.
enum WearerDotFreshness: Equatable, Sendable {
    /// Solid dot.
    case fresh
    /// Solid dot plus an age ("2 min ago"), or "updating…" on a live route.
    case aged(seconds: TimeInterval)
    /// Grey hollow dot; the distance greyed with "as of 10:42", or on a live route "Phone not
    /// nearby — the map will catch up".
    case stale

    /// A place / where-am-I / places card: fresh under 60 s, aged to 5 min, stale beyond.
    static func forCard(fixAt: Date, now: Date) -> WearerDotFreshness {
        let age = max(0, now.timeIntervalSince(fixAt))
        if age < 60 { return .fresh }
        if age <= 5 * 60 { return .aged(seconds: age) }
        return .stale
    }

    /// A live route: fresh under 10 s since the last delta, aged to 30 s, stale beyond.
    static func forRoute(lastDeltaAt: Date, now: Date) -> WearerDotFreshness {
        let age = max(0, now.timeIntervalSince(lastDeltaAt))
        if age < 10 { return .fresh }
        if age <= 30 { return .aged(seconds: age) }
        return .stale
    }

    /// Whole minutes for an "N min ago" label (at least 1).
    static func minutesAgo(_ seconds: TimeInterval) -> Int {
        max(1, Int(seconds / 60))
    }
}

// MARK: - Distance text

/// A short distance for a card ("847 m", "1.2 km", "450 ft", "2.3 mi") — the rules of the phone's
/// `DistanceFormatter.compact`, which the watch does not compile, so the wrist shows the figure the
/// phone said.
enum GlanceDistanceText {
    static func short(meters: Double, metric: Bool) -> String {
        let meters = Int(max(0, meters).rounded())
        if metric {
            if meters < 1_000 { return "\(meters) m" }
            return String(format: "%.1f km", Double(meters) / 1_000)
        }
        let feet = Double(meters) * 3.280_84
        if feet < 1_000 { return "\(Int((feet / 10).rounded()) * 10) ft" }
        return String(format: "%.1f mi", Double(meters) / 1_609.344)
    }
}

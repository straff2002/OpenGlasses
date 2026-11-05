import CoreLocation
import Foundation
import MapKit

/// Plan GM P1a — the phone-only conversion from MapKit and CoreLocation values into the shared
/// surface model. Pure: map items and fixes in, `GlanceSurface` out, no MapKit request.
enum GlanceSurfaceBuilder {

    /// One nearby result, before it becomes a row.
    struct Candidate: Equatable {
        let name: String
        let category: String?
        let coordinate: GlancePoint
        /// Straight-line metres from the wearer, as spoken.
        let meters: Double
    }

    static func point(_ coordinate: CLLocationCoordinate2D) -> GlancePoint {
        GlancePoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func wearer(_ location: CLLocation) -> WearerFix {
        WearerFix(coordinate: point(location.coordinate), fixAt: location.timestamp,
                  horizontalAccuracy: location.horizontalAccuracy)
    }

    // MARK: - Surfaces

    static func place(name: String, subtitle: String?, coordinate: GlancePoint, wearer: WearerFix?,
                      routeMeters: Double? = nil, etas: [GlanceETA] = [],
                      mapAllowed: Bool, now: Date, id: String = UUID().uuidString) -> GlanceSurface {
        let straight = wearer.map { GlanceGeometry.distanceMeters($0.coordinate, coordinate) } ?? 0
        let bearing = wearer.map { GlanceGeometry.initialBearingDegrees(from: $0.coordinate, to: coordinate) } ?? 0
        let card = PlaceCard(name: name, subtitle: subtitle, coordinate: coordinate, wearer: wearer,
                             straightLineMeters: straight, bearingDegrees: bearing,
                             routeMeters: routeMeters, etas: etas)
        return surface(.place(card), mapAllowed: mapAllowed, now: now, id: id)
    }

    static func whereAmI(wearer: WearerFix, street: String?, locality: String?,
                         mapAllowed: Bool, now: Date, id: String = UUID().uuidString) -> GlanceSurface {
        surface(.whereAmI(WhereCard(wearer: wearer, street: street, locality: locality)),
                mapAllowed: mapAllowed, now: now, id: id)
    }

    /// Rows in the order given — the order the answer speaks them — capped at
    /// `PlacesCard.maxRows`.
    static func places(query: String, candidates: [Candidate], wearer: WearerFix?,
                       mapAllowed: Bool, now: Date, id: String = UUID().uuidString) -> GlanceSurface {
        let rows = candidates.prefix(PlacesCard.maxRows).enumerated().map { index, candidate in
            PlaceRow(id: String(index), name: candidate.name, category: candidate.category,
                     meters: candidate.meters, coordinate: candidate.coordinate)
        }
        return surface(.places(PlacesCard(query: query, rows: rows, wearer: wearer)),
                       mapAllowed: mapAllowed, now: now, id: id)
    }

    // MARK: - Map items

    /// Candidates from search results, in their order — the order the answer speaks them.
    static func candidates(from items: [MKMapItem], wearer: CLLocation?) -> [Candidate] {
        items.map { item in
            let location = item.location
            return Candidate(name: item.name ?? String(localized: "Unknown"),
                             category: categoryWords(item.pointOfInterestCategory),
                             coordinate: point(location.coordinate),
                             meters: wearer.map { $0.distance(from: location) } ?? 0)
        }
    }

    /// "MKPOICategoryPublicTransport" → "Public transport"; "MKPOICategoryEVCharger" →
    /// "EV charger" (a run of capitals is an acronym and keeps its case).
    static func categoryWords(_ category: MKPointOfInterestCategory?) -> String? {
        guard var raw = category?.rawValue else { return nil }
        if raw.hasPrefix("MKPOICategory") { raw.removeFirst("MKPOICategory".count) }
        let characters = Array(raw)
        guard !characters.isEmpty else { return nil }
        var words: [String] = []
        var word = ""
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord = character.isUppercase && previous != nil
                && (previous!.isLowercase || next?.isLowercase == true)
            if startsWord, !word.isEmpty {
                words.append(word)
                word = ""
            }
            word.append(character)
        }
        words.append(word)
        return words.enumerated().map { index, word in
            let isAcronym = word.count > 1 && word.allSatisfy(\.isUppercase)
            return index == 0 || isAcronym ? word : word.lowercased()
        }.joined(separator: " ")
    }

    // MARK: -

    private static func surface(_ kind: GlanceSurface.Kind, mapAllowed: Bool, now: Date,
                                id: String) -> GlanceSurface {
        GlanceSurface(id: id, createdAt: now,
                      expiresAt: GlanceSurfacePolicy.lifetime(of: kind).map { now.addingTimeInterval($0) },
                      mapAllowed: mapAllowed, kind: kind)
    }
}

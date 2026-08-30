import CoreLocation
import Foundation
import MapKit

struct MyDayCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coreLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MyDayTravelSettings: Equatable, Sendable {
    let mode: MyDayTransportMode
    let bufferMinutes: Int
    let origin: MyDayTravelOrigin
    let homeAddress: String
    let workAddress: String

    static var current: Self {
        .init(
            mode: Config.myDayTransportMode,
            bufferMinutes: Config.myDayTravelBufferMinutes,
            origin: Config.myDayTravelOrigin,
            homeAddress: Config.myDayHomeAddress,
            workAddress: Config.myDayWorkAddress
        )
    }
}

enum MyDayTravelPlanner {
    static func nextLocatableEvent(
        in events: [MyDayCalendarEvent],
        now: Date
    ) -> MyDayCalendarEvent? {
        events
            .filter { !$0.isAllDay && $0.startDate > now && usableDestination($0.location) != nil }
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.id < $1.id
            }
            .first
    }

    static func usableDestination(_ location: String?) -> String? {
        guard let location else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let lower = trimmed.lowercased()
        let virtualMarkers = [
            "http://", "https://", "zoom", "microsoft teams", "google meet", "webex",
            "facetime", "online", "virtual", "phone call", "tbd"
        ]
        guard !virtualMarkers.contains(where: lower.contains) else { return nil }
        return trimmed
    }

    static func estimate(
        event: MyDayCalendarEvent,
        destination: String,
        travelDuration: TimeInterval,
        settings: MyDayTravelSettings
    ) -> MyDayTravelEstimate? {
        guard travelDuration.isFinite, travelDuration > 0 else { return nil }
        let buffer = TimeInterval(min(60, max(0, settings.bufferMinutes)) * 60)
        return .init(
            eventID: event.id,
            eventTitle: event.title,
            destination: destination,
            eventStart: event.startDate,
            travelDuration: travelDuration,
            bufferDuration: buffer,
            leaveAt: event.startDate.addingTimeInterval(-(travelDuration + buffer)),
            mode: settings.mode
        )
    }
}

struct MyDayTravelCacheMetadata: Equatable, Sendable {
    let eventID: String
    let eventStart: Date
    let destinationKey: String
    let origin: MyDayCoordinate
    let originMode: MyDayTravelOrigin
    let transportMode: MyDayTransportMode
    let bufferMinutes: Int
    let calculatedAt: Date
}

enum MyDayTravelCachePolicy {
    static let lifetime: TimeInterval = 5 * 60
    static let materialLocationChangeMeters = 250.0

    static func canReuse(
        _ cached: MyDayTravelCacheMetadata,
        event: MyDayCalendarEvent,
        destinationKey: String,
        origin: MyDayCoordinate,
        settings: MyDayTravelSettings,
        now: Date
    ) -> Bool {
        guard now.timeIntervalSince(cached.calculatedAt) >= 0,
              now.timeIntervalSince(cached.calculatedAt) <= lifetime,
              cached.eventID == event.id,
              cached.eventStart == event.startDate,
              cached.destinationKey == destinationKey,
              cached.originMode == settings.origin,
              cached.transportMode == settings.mode,
              cached.bufferMinutes == min(60, max(0, settings.bufferMinutes)) else {
            return false
        }
        return distanceMeters(from: cached.origin, to: origin) <= materialLocationChangeMeters
    }

    static func distanceMeters(from: MyDayCoordinate, to: MyDayCoordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let deltaLat = (to.latitude - from.latitude) * .pi / 180
        let deltaLon = (to.longitude - from.longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

struct MyDayLeaveByAlert: Equatable, Sendable {
    let id: String
    let eventID: String
    let eventStart: Date
    let message: String
}

enum MyDayLeaveByAlertPolicy {
    /// Inside two minutes the existing "starting now" calendar alert is clearer than a late
    /// route warning, so only one of the two delivery paths fires.
    static let imminentEventWindow: TimeInterval = 2 * 60

    static func alert(for estimate: MyDayTravelEstimate, now: Date) -> MyDayLeaveByAlert? {
        guard now >= estimate.leaveAt,
              now < estimate.eventStart,
              estimate.eventStart.timeIntervalSince(now) > imminentEventWindow else {
            return nil
        }
        let minutes = max(1, Int((estimate.travelDuration / 60).rounded()))
        let occurrence = Int(estimate.eventStart.timeIntervalSince1970)
        let mode = estimate.mode.displayName.lowercased()
        return .init(
            id: "leave-by:\(estimate.eventID):\(occurrence)",
            eventID: estimate.eventID,
            eventStart: estimate.eventStart,
            message: "Leave now for \(estimate.eventTitle). Allow about \(minutes) minutes \(mode) to \(estimate.destination)."
        )
    }
}

@MainActor
final class MapKitTravelTimeDaySource: TravelTimeDaySource {
    private struct CacheEntry {
        let metadata: MyDayTravelCacheMetadata
        let estimate: MyDayTravelEstimate
        let originQuery: String?
        let destinationQuery: String
    }

    private weak var locationService: LocationService?
    private let settings: () -> MyDayTravelSettings
    private var cache: CacheEntry?

    init(
        locationService: LocationService,
        settings: @escaping () -> MyDayTravelSettings = { .current }
    ) {
        self.locationService = locationService
        self.settings = settings
    }

    func loadTravel(
        for events: [MyDayCalendarEvent],
        now: Date
    ) async -> MyDaySourceLoad<MyDayTravelEstimate?> {
        guard let event = MyDayTravelPlanner.nextLocatableEvent(in: events, now: now),
              let destinationQuery = MyDayTravelPlanner.usableDestination(event.location) else {
            cache = nil
            return .init(value: nil, state: .available(.travel))
        }

        let currentSettings = settings()
        let originResult = await resolveOrigin(settings: currentSettings)
        guard case .success(let origin) = originResult else {
            let message: String
            let availability: MyDaySourceAvailability
            switch originResult {
            case .missingConfiguredOrigin(let name):
                message = "Add a \(name) address in My Day settings."
                availability = .unavailable
            case .locationDenied:
                message = "Location access is off."
                availability = .denied
            case .unavailable:
                message = "Your travel origin is unavailable."
                availability = .unavailable
            case .success:
                preconditionFailure("Handled above")
            }
            return .init(
                value: nil,
                state: .init(source: .travel, availability: availability, message: message)
            )
        }

        let destinationKey = normalized(destinationQuery)
        if let cache,
           MyDayTravelCachePolicy.canReuse(
               cache.metadata,
               event: event,
               destinationKey: destinationKey,
               origin: origin,
               settings: currentSettings,
               now: now
           ) {
            return .init(value: cache.estimate, state: .available(.travel))
        }

        do {
            let destination = try await resolvePlace(destinationQuery, near: origin)
            let duration = try await routeDuration(
                from: origin,
                to: destination,
                mode: currentSettings.mode
            )
            guard let estimate = MyDayTravelPlanner.estimate(
                event: event,
                destination: destination.name ?? destinationQuery,
                travelDuration: duration,
                settings: currentSettings
            ) else {
                throw TravelError.noRoute
            }
            cache = CacheEntry(
                metadata: .init(
                    eventID: event.id,
                    eventStart: event.startDate,
                    destinationKey: destinationKey,
                    origin: origin,
                    originMode: currentSettings.origin,
                    transportMode: currentSettings.mode,
                    bufferMinutes: min(60, max(0, currentSettings.bufferMinutes)),
                    calculatedAt: now
                ),
                estimate: estimate,
                originQuery: configuredOriginQuery(for: currentSettings),
                destinationQuery: destinationQuery
            )
            return .init(value: estimate, state: .available(.travel))
        } catch {
            cache = nil
            return .init(
                value: nil,
                state: .unavailable(.travel, message: "Travel time could not be estimated.")
            )
        }
    }

    func directionsURL(for eventID: String) -> URL? {
        guard let cache, cache.estimate.eventID == eventID else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        var queryItems = [
            URLQueryItem(name: "daddr", value: cache.destinationQuery),
            URLQueryItem(name: "dirflg", value: cache.estimate.mode.mapsFlag)
        ]
        if let originQuery = cache.originQuery {
            queryItems.insert(URLQueryItem(name: "saddr", value: originQuery), at: 0)
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func configuredOriginQuery(for settings: MyDayTravelSettings) -> String? {
        switch settings.origin {
        case .currentLocation:
            nil
        case .home:
            settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        case .work:
            settings.workAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private enum OriginResult {
        case success(MyDayCoordinate)
        case missingConfiguredOrigin(String)
        case locationDenied
        case unavailable
    }

    private func resolveOrigin(settings: MyDayTravelSettings) async -> OriginResult {
        switch settings.origin {
        case .currentLocation:
            guard let locationService else { return .unavailable }
            if let fix = await locationService.awaitFix(timeout: 2.5) {
                return .success(MyDayCoordinate(fix.coordinate))
            }
            switch locationService.authorizationStatus {
            case .denied, .restricted:
                return .locationDenied
            default:
                return .unavailable
            }
        case .home, .work:
            let name = settings.origin == .home ? "Home" : "Work"
            let address = settings.origin == .home ? settings.homeAddress : settings.workAddress
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .missingConfiguredOrigin(name) }
            guard let item = try? await resolvePlace(trimmed, near: nil) else { return .unavailable }
            return .success(MyDayCoordinate(item.location.coordinate))
        }
    }

    private func resolvePlace(_ query: String, near origin: MyDayCoordinate?) async throws -> MKMapItem {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let origin {
            request.region = MKCoordinateRegion(
                center: origin.coreLocation,
                latitudinalMeters: 50_000,
                longitudinalMeters: 50_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw TravelError.noPlace }
        return item
    }

    private func routeDuration(
        from origin: MyDayCoordinate,
        to destination: MKMapItem,
        mode: MyDayTransportMode
    ) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
            address: nil
        )
        request.destination = destination
        request.transportType = mode.mapKitType
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw TravelError.noRoute }
        return route.expectedTravelTime
    }

    private func normalized(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private enum TravelError: Error {
        case noPlace
        case noRoute
    }
}

private extension MyDayTransportMode {
    var mapKitType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .driving: .automobile
        case .transit: .transit
        }
    }

    var mapsFlag: String {
        switch self {
        case .walking: "w"
        case .driving: "d"
        case .transit: "r"
        }
    }
}

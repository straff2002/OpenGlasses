import CoreLocation
import Foundation

/// Weather from Apple's WeatherKit: current conditions, today's high and low, rain starting or
/// stopping within the next hour (where the region has a minute forecast), active severe-weather
/// alerts, and the next two days.
///
/// The sentence is built by the pure `WeatherPhraser` from a `WeatherReport`; the provider, the
/// location fix, the geocoder, the units and the Medical Local Only check are all injected, so the
/// whole tool runs headless in tests without a request leaving the machine.
final class WeatherTool: NativeTool, @unchecked Sendable {
    let name = "get_weather"
    let description = "Get the weather from Apple Weather for the user's current location or a named place: current conditions, today's high and low, whether rain starts or stops within the next hour (where available), any active severe-weather alerts, and the next two days. Use this for any weather, rain, umbrella or what-to-wear question."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "latitude": [
                "type": "number",
                "description": "Latitude (optional, defaults to user's current location)"
            ],
            "longitude": [
                "type": "number",
                "description": "Longitude (optional, defaults to user's current location)"
            ],
            "location": [
                "type": "string",
                "description": "A place name to get the weather for, e.g. 'Paris' (optional; omit for the user's current location)"
            ]
        ],
        "required": [] as [String]
    ]

    /// Everything the tool reaches outside itself.
    struct Dependencies {
        var provider: any WeatherProviding
        /// A fresh fix, or nil. Awaits briefly: a nil fix is usually transient.
        var currentLocation: @MainActor () async -> CLLocation?
        /// Apple's geocoder, on the phone.
        var geocode: (String) async -> CLLocation?
        /// "Wellington", for the answer's "in …".
        var placeName: (CLLocation) async -> String?
        var units: () -> WeatherUnits
        var now: () -> Date
        /// False under Medical Local Only: the location would leave the phone.
        var isAllowed: () -> Bool
        /// Told when an answer reaches the conversation, so the chat thread can carry Apple's
        /// attribution. Not called for My Day, which draws its own.
        var onAnswered: @MainActor () -> Void
    }

    /// What one look-up produced.
    enum Lookup {
        case answered(text: String, report: WeatherReport)
        /// Medical Local Only.
        case refused(String)
        case failed(WeatherFetchFailure)
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    convenience init(locationService: LocationService,
                     provider: any WeatherProviding = WeatherKitProvider(),
                     onAnswered: @escaping @MainActor () -> Void = {}) {
        self.init(dependencies: Dependencies(
            provider: provider,
            currentLocation: { await locationService.awaitFix(timeout: 2.0) },
            geocode: { await GeocodingHelper.geocodeAddress($0) },
            placeName: { location in
                guard let place = await GeocodingHelper.reverseGeocode(location) else { return nil }
                return place.cityState ?? place.fullAddress
            },
            units: { WeatherUnits.forLocale(.autoupdatingCurrent) },
            now: { Date() },
            isAllowed: { !MedicalEgressGuard.currentMode().isEnforcing },
            onAnswered: onAnswered
        ))
    }

    func execute(args: [String: Any]) async throws -> String {
        switch await lookUp(args: args) {
        case .answered(let text, _):
            await dependencies.onAnswered()
            return text
        case .refused(let message):
            return message
        case .failed(let failure):
            return failure.spokenMessage
        }
    }

    /// The look-up without the conversation side effects — My Day's entry point.
    func lookUp(args: [String: Any]) async -> Lookup {
        guard dependencies.isAllowed() else { return .refused(MedicalEgressRefusal.userMessage) }

        let target: (location: CLLocation, namedPlace: String?)
        switch await resolveLocation(args: args) {
        case .success(let resolved): target = resolved
        case .failure(let failure): return .failed(failure)
        }

        let coarse = WeatherLocationPrecision.coarsen(
            latitude: target.location.coordinate.latitude,
            longitude: target.location.coordinate.longitude
        )
        let location = CLLocation(latitude: coarse.latitude, longitude: coarse.longitude)

        let report: WeatherReport
        do {
            report = try await dependencies.provider.report(for: location)
        } catch {
            return .failed(WeatherFetchFailure.classify(error))
        }

        let placeName: String?
        if let namedPlace = target.namedPlace {
            placeName = namedPlace
        } else {
            placeName = await dependencies.placeName(location)
        }
        let text = WeatherPhraser.answer(report, placeName: placeName,
                                         units: dependencies.units(), now: dependencies.now())
        return .answered(text: text, report: report)
    }

    // MARK: - Location

    private func resolveLocation(args: [String: Any]) async
        -> Result<(location: CLLocation, namedPlace: String?), WeatherFetchFailure> {
        if let lat = Self.number(args["latitude"]), let lon = Self.number(args["longitude"]),
           (-90...90).contains(lat), (-180...180).contains(lon) {
            let label = (args["location"] as? String).flatMap(Self.cleanPlace)
            return .success((CLLocation(latitude: lat, longitude: lon), label))
        }
        if let place = (args["location"] as? String).flatMap(Self.cleanPlace) {
            guard let found = await dependencies.geocode(place) else { return .failure(.placeNotFound(place)) }
            return .success((found, place))
        }
        guard let fix = await dependencies.currentLocation() else { return .failure(.noLocation) }
        return .success((fix, nil))
    }

    /// A model may send numbers as numbers or as strings.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A usable place name, or nil for blanks and for phrases that mean "where I am".
    static func cleanPlace(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hereWords: Set<String> = ["here", "current location", "my location", "current", "near me", "where i am"]
        return hereWords.contains(trimmed.lowercased()) ? nil : trimmed
    }
}

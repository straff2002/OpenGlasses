import Combine
import CoreLocation
import Foundation
import MapKit

/// Plan CA — the live edge of walking navigation: resolves a spoken destination
/// (`MKLocalSearch`), requests a walking route (`MKDirections`), feeds `LocationService`
/// fixes through the pure `RouteProgressTracker`, renders the active maneuver on the HUD, and
/// speaks cues with urgency scaling. Walking only; no map tiles on the HUD (text card + arrow
/// glyph — the in-lens surface is a token DSL); offline routing is out of scope (MapKit needs
/// network). Real-walk GPS quality, reroute tuning, and backgrounded guidance are
/// device-pending.
@MainActor
final class WalkingRouteService: ObservableObject {

    enum NavState: Equatable {
        case idle
        case resolving(String)
        case guiding(destination: String)
        case arrived(destination: String)
    }

    @Published private(set) var state: NavState = .idle
    @Published private(set) var currentHUDLine: String?

    /// Wired by AppState.
    weak var locationService: LocationService?
    weak var glassesDisplay: GlassesDisplayService?
    var speak: ((String, TextToSpeechService.SpeechUrgency) -> Void)?
    var powerPosture: () -> PowerPosture = { PowerPolicyService.shared.posture }

    private var tracker: RouteProgressTracker?
    private var cuePolicy = NavigationCuePolicy()
    private var destinationItem: MKMapItem?
    private var destinationName = ""
    private var lastRenderedBand: Int = -1
    private var fixSubscription: AnyCancellable?
    private var rerouting = false

    /// Metric unless the units override (or locale) says otherwise.
    var usesMetric: Bool {
        switch Config.navigationUnits {
        case .metric: return true
        case .imperial: return false
        case .auto: return Locale.current.measurementSystem == .metric
        }
    }

    // MARK: - Entry

    /// Resolve `query` near the user and start guiding to the top candidate. Returns the
    /// spoken confirmation (the tool's reply), or throws with a speakable message.
    @discardableResult
    func start(destination query: String) async throws -> String {
        stop(announce: false)
        state = .resolving(query)

        guard let origin = await locationService?.awaitFix(timeout: 3) else {
            state = .idle
            throw NavigationError.noLocation
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: origin.coordinate,
                                            latitudinalMeters: 5_000, longitudinalMeters: 5_000)
        let search = try await MKLocalSearch(request: request).start()
        // Open decision resolved for hands-free flow: confirm-top-candidate (no pick list).
        guard let top = search.mapItems.first else {
            state = .idle
            throw NavigationError.noMatch(query)
        }

        let name = top.name ?? query
        let route = try await walkingRoute(from: origin.coordinate, to: top)
        beginGuiding(route: route, origin: origin.coordinate, destination: top, name: name)

        Config.addRecentDestination(name)
        let distance = DistanceFormatter.spoken(DistanceFormatter.banded(route.distance), metric: usesMetric)
        let eta = Self.etaPhrase(seconds: route.expectedTravelTime)
        return "Starting walking directions to \(name) — \(distance), about \(eta)."
    }

    func stop(announce: Bool) {
        fixSubscription = nil
        tracker = nil
        destinationItem = nil
        if state != .idle {
            locationService?.endPrecisionGuidance()
            glassesDisplay?.clear()
        }
        currentHUDLine = nil
        lastRenderedBand = -1
        state = .idle
        if announce { speak?("Navigation stopped.", .low) }
    }

    /// "How far to go?" — the tool's status reply.
    func statusSummary() -> String {
        guard case .guiding(let destination) = state, let tracker else {
            return "Navigation isn't running."
        }
        guard let remaining = tracker.remainingDistance else {
            return "Walking to \(destination) — waiting for a GPS fix."
        }
        let distance = DistanceFormatter.spoken(DistanceFormatter.banded(remaining), metric: usesMetric)
        return "\(distance) to \(destination)."
    }

    // MARK: - Routing

    private func walkingRoute(from origin: CLLocationCoordinate2D, to item: MKMapItem) async throws -> MKRoute {
        let request = MKDirections.Request()
        // A coordinate-only origin: no address to attach, which is all `MKDirections` reads.
        request.source = MKMapItem(
            location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
            address: nil)
        request.destination = item
        request.transportType = .walking
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw NavigationError.noRoute }
        return route
    }

    private func beginGuiding(route: MKRoute, origin: CLLocationCoordinate2D,
                              destination: MKMapItem, name: String) {
        let steps = Self.buildSteps(route: route, origin: origin)
        tracker = RouteProgressTracker(steps: steps)
        cuePolicy = NavigationCuePolicy()
        destinationItem = destination
        destinationName = name
        lastRenderedBand = -1
        state = .guiding(destination: name)

        locationService?.beginPrecisionGuidance()
        fixSubscription = locationService?.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.handleFix(location)
            }
    }

    /// Map `MKRoute` into the pure model. MapKit's step instruction applies at the *start* of
    /// that step's polyline, so our step's maneuver point is its polyline head and the inbound
    /// leg is the previous step's polyline. A missing final arrive step is synthesized.
    nonisolated static func buildSteps(route: MKRoute, origin: CLLocationCoordinate2D) -> [RouteStep] {
        let mkSteps = route.steps.filter { !$0.instructions.isEmpty || $0 === route.steps.first }
        var steps: [RouteStep] = []
        var previousLeg: [RoutePoint] = [RoutePoint(lat: origin.latitude, lon: origin.longitude)]
        var previousDistance: Double = 0

        for (index, mkStep) in mkSteps.enumerated() {
            let coords = polylinePoints(mkStep.polyline)
            let maneuverPoint = coords.first ?? previousLeg.last!
            let instruction = mkStep.instructions.isEmpty ? "Head out" : mkStep.instructions
            let maneuver: Maneuver = index == 0 ? .depart : Maneuver.parse(instruction: instruction)
            steps.append(RouteStep(
                instruction: instruction,
                maneuver: maneuver,
                streetName: Self.streetName(from: instruction),
                maneuverPoint: maneuverPoint,
                inboundLeg: previousLeg.count > 1 ? previousLeg : [maneuverPoint],
                inboundDistance: previousDistance))
            previousLeg = coords.isEmpty ? [maneuverPoint] : coords
            previousDistance = mkStep.distance
        }

        if steps.last?.maneuver != .arrive {
            let destination = previousLeg.last ?? RoutePoint(lat: origin.latitude, lon: origin.longitude)
            steps.append(RouteStep(
                instruction: "Arrive at your destination",
                maneuver: .arrive, streetName: nil,
                maneuverPoint: destination,
                inboundLeg: previousLeg, inboundDistance: previousDistance))
        }
        return steps
    }

    nonisolated private static func polylinePoints(_ polyline: MKPolyline) -> [RoutePoint] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                              count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords.map { RoutePoint(lat: $0.latitude, lon: $0.longitude) }
    }

    /// "Turn left onto King Street" → "King Street". Conservative: nil when no marker.
    nonisolated static func streetName(from instruction: String) -> String? {
        for marker in [" onto ", " on to ", " on "] {
            if let range = instruction.range(of: marker) {
                let street = String(instruction[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
                return street.isEmpty ? nil : street
            }
        }
        return nil
    }

    nonisolated static func etaPhrase(seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hour\(hours == 1 ? "" : "s")" : "\(hours) h \(rest) min"
    }

    // MARK: - Guidance loop

    private func handleFix(_ location: CLLocation) {
        guard case .guiding = state, tracker != nil else { return }
        let event = tracker!.accept(lat: location.coordinate.latitude,
                                    lon: location.coordinate.longitude,
                                    accuracy: max(5, location.horizontalAccuracy),
                                    now: Date())
        switch event {
        case .arrived:
            glassesDisplay?.showNavigation("⚑ \(destinationName)", icon: .success)
            if Config.navigationVoiceCues { speak?("You've arrived at \(destinationName).", .high) }
            state = .arrived(destination: destinationName)
            locationService?.endPrecisionGuidance()
            fixSubscription = nil
            return
        case .offRoute:
            reroute()
            return
        case .advancedTo, .none:
            renderActiveStep()
        }
    }

    private func renderActiveStep() {
        guard let tracker, let step = tracker.activeStep,
              let distance = tracker.distanceToManeuver else { return }
        let band = DistanceFormatter.banded(distance)

        // Power reserve (Plan BV): no continuous countdown — the HUD updates only when a cue
        // fires; turns are still spoken.
        let cue = cuePolicy.cue(stepIndex: tracker.activeStepIndex, bandedMeters: band)
        let reserveMode = powerPosture() == .reserve

        if band != lastRenderedBand, !reserveMode || cue != nil {
            lastRenderedBand = band
            let line = ManeuverPhraser.hudLine(maneuver: step.maneuver, streetName: step.streetName,
                                               bandedMeters: band, metric: usesMetric)
            currentHUDLine = line
            glassesDisplay?.showNavigation(line)
        }

        if let cue, Config.navigationVoiceCues {
            let phrase = ManeuverPhraser.spoken(maneuver: step.maneuver, streetName: step.streetName,
                                                bandedMeters: band, metric: usesMetric)
            // An imminent turn speaks over anything; an approach cue is routine.
            speak?(phrase, cue == .imminent ? .high : .medium)
        }
    }

    private func reroute() {
        guard !rerouting, let destination = destinationItem,
              let origin = locationService?.currentLocation else { return }
        rerouting = true
        if Config.navigationVoiceCues { speak?("Rerouting.", .medium) }
        Task { [weak self] in
            guard let self else { return }
            defer { self.rerouting = false }
            do {
                let route = try await self.walkingRoute(from: origin.coordinate, to: destination)
                guard case .guiding = self.state else { return }
                self.beginGuiding(route: route, origin: origin.coordinate,
                                  destination: destination, name: self.destinationName)
            } catch {
                NSLog("[Navigation] Reroute failed: %@", error.localizedDescription)
                self.speak?("I couldn't find a new route.", .medium)
            }
        }
    }
}

enum NavigationError: LocalizedError {
    case noLocation
    case noMatch(String)
    case noRoute

    var errorDescription: String? {
        switch self {
        case .noLocation:
            return "I couldn't get your location — check location permissions."
        case .noMatch(let query):
            return "I couldn't find \(query) nearby."
        case .noRoute:
            return "No walking route found."
        }
    }
}

// MARK: - Config

enum NavigationUnits: String, CaseIterable {
    case auto, metric, imperial

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }
}

extension Config {
    static var navigationUnits: NavigationUnits {
        get {
            UserDefaults.standard.string(forKey: "navigationUnits")
                .flatMap(NavigationUnits.init(rawValue:)) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "navigationUnits") }
    }

    static var navigationVoiceCues: Bool {
        get { UserDefaults.standard.object(forKey: "navigationVoiceCues") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "navigationVoiceCues") }
    }

    /// Most-recent-first, deduplicated, capped — backs the HUD launcher's Navigate branch.
    static var recentDestinations: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "recentDestinations") }
    }

    static func addRecentDestination(_ name: String) {
        var recents = recentDestinations.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        recents.insert(name, at: 0)
        recentDestinations = Array(recents.prefix(5))
    }
}

import Foundation

/// Plan CA — the heart of walking guidance, pure: ordered steps + a stream of GPS fixes in,
/// step advancement / off-route / arrival decisions out. GPS reality is designed in — every
/// radius scales with the fix's reported `horizontalAccuracy`, and off-route needs K
/// consecutive bad fixes plus a reroute throttle so one urban-canyon bounce can't thrash
/// the route.
struct RouteProgressTracker {

    struct Configuration {
        /// Base advance radius around a maneuver point (m); the effective radius is
        /// `max(advanceRadius, accuracy)`.
        var advanceRadius: Double = 20
        /// Base perpendicular distance from the inbound leg that counts as off-route; the
        /// effective threshold is `max(offRouteThreshold, accuracy * 1.5)`.
        var offRouteThreshold: Double = 30
        /// Consecutive off-route fixes required before a reroute is requested.
        var offRouteFixes: Int = 4
        /// Minimum seconds between reroute requests.
        var rerouteThrottle: TimeInterval = 30
        /// Base arrival radius around the destination (m); effective `max(radius, accuracy)`.
        var arrivalRadius: Double = 25
    }

    enum Event: Equatable {
        case none
        case advancedTo(Int)
        case offRoute
        case arrived
    }

    let steps: [RouteStep]
    let config: Configuration

    private(set) var activeStepIndex = 0
    private(set) var distanceToManeuver: Double?
    private(set) var finished = false
    private var offRouteStreak = 0
    private var lastRerouteRequest: Date?

    init(steps: [RouteStep], config: Configuration = Configuration()) {
        self.steps = steps
        self.config = config
    }

    var activeStep: RouteStep? {
        guard steps.indices.contains(activeStepIndex) else { return nil }
        return steps[activeStepIndex]
    }

    /// Meters left to the destination: distance to the active maneuver plus every later leg.
    var remainingDistance: Double? {
        guard let toManeuver = distanceToManeuver, steps.indices.contains(activeStepIndex) else { return nil }
        let laterLegs = steps.suffix(from: activeStepIndex + 1).reduce(0) { $0 + $1.inboundDistance }
        return toManeuver + laterLegs
    }

    mutating func accept(lat: Double, lon: Double, accuracy: Double, now: Date) -> Event {
        guard !finished, let active = activeStep else { return .none }
        let fix = RoutePoint(lat: lat, lon: lon)
        let toManeuver = RouteGeometry.metersDistance(fix, active.maneuverPoint)
        distanceToManeuver = toManeuver

        // Arrival — the final step only.
        if activeStepIndex == steps.count - 1 {
            if toManeuver <= max(config.arrivalRadius, accuracy) {
                finished = true
                return .arrived
            }
        } else if toManeuver <= max(config.advanceRadius, accuracy) {
            // Advance to the next step; recompute against its maneuver point.
            activeStepIndex += 1
            offRouteStreak = 0
            distanceToManeuver = RouteGeometry.metersDistance(fix, steps[activeStepIndex].maneuverPoint)
            return .advancedTo(activeStepIndex)
        }

        // Off-route: perpendicular distance from the leg being walked. The *next* leg counts
        // too — cutting a corner slightly early is progress, not a detour.
        var offLeg = RouteGeometry.distanceToLeg(fix, leg: active.inboundLeg)
        if activeStepIndex + 1 < steps.count {
            offLeg = min(offLeg, RouteGeometry.distanceToLeg(fix, leg: steps[activeStepIndex + 1].inboundLeg))
        }
        if offLeg > max(config.offRouteThreshold, accuracy * 1.5) {
            offRouteStreak += 1
        } else {
            offRouteStreak = 0
        }
        if offRouteStreak >= config.offRouteFixes {
            offRouteStreak = 0
            if lastRerouteRequest.map({ now.timeIntervalSince($0) >= config.rerouteThrottle }) ?? true {
                lastRerouteRequest = now
                return .offRoute
            }
        }
        return .none
    }
}

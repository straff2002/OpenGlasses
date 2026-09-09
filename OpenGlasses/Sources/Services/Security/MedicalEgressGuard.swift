import Foundation

/// A refusal from ``MedicalEgressGuard``. Carries the route so a caller can log or surface which
/// feature was stopped without restating the policy.
struct MedicalEgressRefusal: Error, Equatable, LocalizedError, CustomStringConvertible {
    let route: NetworkRoute

    var description: String {
        "\(route.rawValue) is blocked: Medical Compliance is in Local Only mode, so nothing derived from what the glasses captured may leave this device."
    }

    var errorDescription: String? { description }

    /// The sentence a user-facing surface may show. Deliberately identical for every route so the
    /// mode, not the feature, reads as the cause.
    static let userMessage =
        "Medical Local Only is on, so this needs a connection that isn't allowed right now. "
        + "Turn off Local Only in Medical Compliance settings to use it."
}

/// The one place that decides whether a ``NetworkRoute`` may open while Medical Compliance is in
/// "Local LLM Only" mode.
///
/// ``MedicalLLMRoutingPolicy`` answers the narrower question of *which model* may serve a request.
/// This guard answers the universal one — may these bytes leave at all — for every route in
/// ``NetworkRouteRegistry``, so the promise is enforced at each request-construction point rather
/// than only on the inference path.
///
/// The decision is pure. `currentMode` is the single live seam; tests override it instead of
/// writing to `UserDefaults`.
enum MedicalEgressGuard {

    struct Mode: Equatable, Sendable {
        var hipaaMode: Bool
        var localOnly: Bool

        static let off = Mode(hipaaMode: false, localOnly: false)
        static let localOnly = Mode(hipaaMode: true, localOnly: true)

        /// Matches ``MedicalLLMRoutingPolicy/isEnforced(hipaaMode:localOnly:)`` exactly: the
        /// local-only promise only binds when Medical Compliance itself is on.
        var isEnforcing: Bool { hipaaMode && localOnly }
    }

    enum Decision: Equatable {
        case allow
        case refuse(MedicalEgressRefusal)

        var isAllowed: Bool { self == .allow }
    }

    /// Live mode source. Overridden in tests; the app never assigns it.
    nonisolated(unsafe) static var currentMode: () -> Mode = {
        Mode(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
    }

    // MARK: - Pure decision

    static func decide(_ route: NetworkRoute, mode: Mode) -> Decision {
        guard mode.isEnforcing else { return .allow }
        guard route.medicalPolicy.blocksLocalOnly else { return .allow }
        return .refuse(MedicalEgressRefusal(route: route))
    }

    static func decide(_ route: NetworkRoute, hipaaMode: Bool, localOnly: Bool) -> Decision {
        decide(route, mode: Mode(hipaaMode: hipaaMode, localOnly: localOnly))
    }

    // MARK: - Live call sites

    /// The one-liner every guarded request-construction point calls.
    /// Throws ``MedicalEgressRefusal`` when the route may not open.
    static func check(_ route: NetworkRoute) throws {
        if case .refuse(let refusal) = decide(route, mode: currentMode()) { throw refusal }
    }

    /// The non-throwing form, for call sites whose existing shape is a boolean readiness check or
    /// an early `return` rather than a `throws` function.
    static func allows(_ route: NetworkRoute) -> Bool {
        decide(route, mode: currentMode()).isAllowed
    }

    /// True when the route is currently refused. Reads better at teardown sites.
    static func blocks(_ route: NetworkRoute) -> Bool { !allows(route) }

    /// Every route the current mode refuses. The in-flight coordinator uses this to decide what to
    /// tear down when the mode flips on.
    static var blockedRoutes: [NetworkRoute] {
        let mode = currentMode()
        return NetworkRoute.allCases.filter { !decide($0, mode: mode).isAllowed }
    }
}

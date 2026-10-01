import Foundation

/// Where the conversation is being thought through right now (Plan GE).
enum HandoffRoute: String, Equatable, Sendable {
    /// The configured cloud model, as normal.
    case cloud
    /// On the phone: on-device model, offline tool set, or a held question when nothing can think.
    case phone
}

/// The session-level offline switch (Plan GE P0): decides when an ongoing conversation moves onto
/// the phone and when it moves back to the cloud.
///
/// Before this, nothing decided "we are offline for this conversation". Every turn first waited for
/// the cloud request to fail and only then cascaded to a local model, and the cascade restored the
/// cloud model at the end of the turn — so the next turn paid the same timeout again, and when the
/// signal came back nothing moved back on purpose.
///
/// # The rules
///
/// * **Enter at once** when the path goes `unsatisfied`, or after ``Tuning/failuresToEnterPhone``
///   consecutive connectivity-class failures while the path still claims `satisfied` (a captive
///   portal, a dead cellular bearer — `NWPathMonitor` reads both as online).
/// * **Leave only on a stable return**: the path must have been `satisfied` for
///   ``Tuning/returnStableSeconds`` *and* one probe must succeed. A failed probe restarts the
///   window, and probes back off (20 → 40 → 80 s …) up to ``Tuning/maxProbeBackoff``.
/// * **Never mid-turn.** While a turn is being inferred or spoken the decision is still taken, but
///   the *applied* route only changes at the next turn boundary.
///
/// Pure: the clock comes in as `now`, and the caller runs the probe and reports its result. The
/// numbers are defaults in one struct, pinned by `ConnectivityHandoffPolicyTests`, tunable after
/// device runs.
struct ConnectivityHandoffPolicy: Equatable {

    struct Tuning: Equatable {
        /// Consecutive connectivity-class failures, on a path that claims to be up, before the
        /// conversation moves to the phone.
        var failuresToEnterPhone = 2
        /// How long the path must stay satisfied before a return is even probed.
        var returnStableSeconds: TimeInterval = 20
        /// First probe delay; doubles after every failed probe.
        var initialProbeBackoff: TimeInterval = 20
        /// Ceiling for the probe backoff.
        var maxProbeBackoff: TimeInterval = 300

        static let standard = Tuning()
    }

    enum State: Equatable {
        /// Normal: the cloud answers.
        case cloud
        /// The path claims to be up but cloud turns are failing on connectivity.
        case degraded(failures: Int)
        /// On the phone, with the path down.
        case phone
        /// On the phone, with the path up again: waiting out the stable window and the probe.
        /// `windowStart` is when the current stable window began (path came up, phone was entered
        /// on failures, or the last probe failed).
        case returning(windowStart: Date)
    }

    enum Event: Equatable {
        case pathSatisfied
        case pathUnsatisfied
        /// A cloud attempt failed with a connectivity-class error.
        case connectivityFailure
        /// A cloud attempt succeeded.
        case cloudSuccess
        case probeSucceeded
        case probeFailed
    }

    let tuning: Tuning
    private(set) var state: State
    /// The route turns actually take. Changes only outside a turn.
    private(set) var appliedRoute: HandoffRoute
    private(set) var isPathSatisfied: Bool
    private(set) var isInTurn = false
    /// The delay before the next probe, after the stable window has started.
    private(set) var probeBackoff: TimeInterval
    /// When the next probe may run, or nil when none is due (not on the phone, or path down).
    private(set) var nextProbeAt: Date?

    init(tuning: Tuning = .standard, pathSatisfied: Bool = true, now: Date) {
        self.tuning = tuning
        self.isPathSatisfied = pathSatisfied
        self.probeBackoff = max(tuning.initialProbeBackoff, tuning.returnStableSeconds)
        self.state = pathSatisfied ? .cloud : .phone
        self.appliedRoute = pathSatisfied ? .cloud : .phone
    }

    /// The route the evidence points to, whether or not it has been applied yet.
    var desiredRoute: HandoffRoute {
        switch state {
        case .cloud, .degraded: return .cloud
        case .phone, .returning: return .phone
        }
    }

    /// A route change is waiting for the current turn to end.
    var hasPendingChange: Bool { desiredRoute != appliedRoute }

    // MARK: - Events

    /// Feed one event. Returns the new applied route when it changed.
    @discardableResult
    mutating func handle(_ event: Event, now: Date) -> HandoffRoute? {
        switch event {
        case .pathUnsatisfied:
            isPathSatisfied = false
            state = .phone
            nextProbeAt = nil
            // A real drop ends whatever probing a captive portal had driven the backoff up to: the
            // next time the path comes back, the first probe is at the normal delay.
            probeBackoff = max(tuning.initialProbeBackoff, tuning.returnStableSeconds)

        case .pathSatisfied:
            isPathSatisfied = true
            if case .phone = state { startWindow(now: now) }

        case .connectivityFailure:
            switch state {
            case .cloud:
                state = tuning.failuresToEnterPhone <= 1 ? .phone : .degraded(failures: 1)
            case .degraded(let failures):
                state = failures + 1 >= tuning.failuresToEnterPhone ? .phone : .degraded(failures: failures + 1)
            case .phone, .returning:
                break
            }
            // Entered on failures while the path still claims to be up: the window starts now, so
            // the same captive portal is not trusted again on the strength of the path alone.
            if case .phone = state, isPathSatisfied { startWindow(now: now) }

        case .cloudSuccess:
            if case .degraded = state { state = .cloud }

        case .probeSucceeded:
            guard case .returning(let windowStart) = state, isPathSatisfied,
                  now.timeIntervalSince(windowStart) >= tuning.returnStableSeconds else { break }
            state = .cloud
            nextProbeAt = nil
            probeBackoff = max(tuning.initialProbeBackoff, tuning.returnStableSeconds)

        case .probeFailed:
            guard case .returning = state else { break }
            probeBackoff = min(probeBackoff * 2, tuning.maxProbeBackoff)
            state = .returning(windowStart: now)
            nextProbeAt = now.addingTimeInterval(probeBackoff)
        }
        return applyIfIdle()
    }

    // MARK: - Turn boundaries

    /// A turn started inferring or speaking: route changes wait until it ends.
    mutating func beginTurn() { isInTurn = true }

    /// The turn ended. Returns the new applied route when a pending change was applied.
    @discardableResult
    mutating func endTurn() -> HandoffRoute? {
        isInTurn = false
        return applyIfIdle()
    }

    // MARK: - Probing

    /// Whether a probe should run now: on the phone, path up, stable window elapsed, backoff
    /// reached.
    func isProbeDue(now: Date) -> Bool {
        guard case .returning(let windowStart) = state, isPathSatisfied,
              now.timeIntervalSince(windowStart) >= tuning.returnStableSeconds,
              let nextProbeAt else { return false }
        return now >= nextProbeAt
    }

    // MARK: - Private

    private mutating func startWindow(now: Date) {
        state = .returning(windowStart: now)
        nextProbeAt = now.addingTimeInterval(max(probeBackoff, tuning.returnStableSeconds))
    }

    private mutating func applyIfIdle() -> HandoffRoute? {
        guard !isInTurn, desiredRoute != appliedRoute else { return nil }
        appliedRoute = desiredRoute
        return appliedRoute
    }
}

/// Whether an error says the network, rather than the model or the request, failed (Plan GE).
/// These are what count toward moving the conversation onto the phone.
enum ConnectivityFailure {
    static let codes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed,
        .callIsActive, .secureConnectionFailed,
    ]

    static func isConnectivityFailure(_ error: Error) -> Bool {
        if let url = error as? URLError { return codes.contains(url.code) }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return codes.contains(URLError.Code(rawValue: ns.code)) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isConnectivityFailure(underlying)
        }
        return false
    }
}

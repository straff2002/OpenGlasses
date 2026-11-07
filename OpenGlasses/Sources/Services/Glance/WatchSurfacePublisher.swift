import Combine
import Foundation
import WatchConnectivity

/// The part of `WCSession` the surface push uses, so a test drives a fake and never
/// `WCSession.default`.
protocol WatchSessioning: AnyObject {
    var isActivated: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
}

extension WCSession: WatchSessioning {
    var isActivated: Bool { activationState == .activated }
}

/// Plan GM P1a — puts glance surfaces on the wrist.
///
/// The application context is one dictionary and latest wins, so surfaces cannot be pushed on
/// their own: a context without `job` clears the job on the watch, and a status push without
/// `surfaces` would clear the card. Every push therefore goes through here — the phone's status
/// dictionary (`baseContext`) plus the `surfaces` value, or no `surfaces` key at all when nothing
/// is live, which the watch reads as "clear", as it does for `job`.
///
/// Needs no reachability: the system delivers the context when the watch app next runs.
@MainActor
final class WatchSurfacePublisher {

    static let contextKey = GlanceWire.contextKey

    struct Environment {
        var setting: () -> WatchMapCardsSetting = { Config.watchMapCards }
        var medical: () -> MedicalEgressGuard.Mode = { MedicalEgressGuard.currentMode() }
        var usesMetric: () -> Bool = { ParkingTool.prefersMetric }
        var sendsLongLists: () -> Bool = { Config.watchSendsLongLists }
        var now: () -> Date = Date.init
    }

    private let session: WatchSessioning
    private let environment: Environment
    private let baseContext: () -> [String: Any]?
    /// Today's calendar and weather (Plan KS), folded into every push like `surfaces`.
    private let todayValue: () -> Data?
    private var held = GlanceSurfaceSet()
    private var busSubscription: AnyCancellable?
    private var expiryTask: Task<Void, Never>?

    /// What the last push carried, for tests and diagnostics.
    private(set) var lastPushedSet: GlanceSurfaceSet?

    init(session: WatchSessioning, environment: Environment = Environment(),
         todayValue: @escaping () -> Data? = { nil },
         baseContext: @escaping () -> [String: Any]?) {
        self.session = session
        self.environment = environment
        self.todayValue = todayValue
        self.baseContext = baseContext
    }

    /// Take every publication on `bus` from now on.
    func observe(_ bus: GlanceSurfaceBus) {
        busSubscription = bus.$latest
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] publication in self?.accept(publication) }
    }

    /// Decide on one publication and, when it goes to the wrist, push it.
    func accept(_ publication: GlanceSurfaceBus.Publication) {
        let inputs = GlanceSurfacePolicy.Inputs(setting: environment.setting(),
                                                asked: publication.asked,
                                                watchAppInstalled: session.isWatchAppInstalled,
                                                medical: environment.medical(),
                                                sendsLongLists: environment.sendsLongLists())
        guard case .send(let mapAllowed, let playsTap) = GlanceSurfacePolicy.decide(publication.surface.kind, inputs) else {
            return
        }
        var surface = publication.surface
        surface.mapAllowed = surface.mapAllowed && mapAllowed
        if case .route = surface.kind {
            held.route = surface
        } else {
            held.current = surface
            held.playsTap = playsTap
        }
        push()
    }

    /// Forget the live route (guidance ended) and push.
    func clearRoute() {
        guard held.route != nil else { return }
        held.route = nil
        push()
    }

    /// The `surfaces` value as it stands, or nil for "absent".
    func contextValue() -> Data? {
        let now = environment.now()
        held = held.live(at: now)
        guard environment.setting() != .never, !held.isEmpty else { return nil }
        var set = held
        set.usesMetric = environment.usesMetric()
        // Medical Local Only may have come on since the card was accepted.
        if !GlanceSurfacePolicy.mapAllowed(environment.medical()) {
            set.current?.mapAllowed = false
            set.route?.mapAllowed = false
        }
        switch GlanceSurfaceCodec.encode(set) {
        case .success(let encoded):
            lastPushedSet = encoded.set
            return encoded.data
        case .failure(.overBudget(let bytes, _)):
            PrivacyLog.device(.watch, .surfaceRefused, reason: PrivacyToken("overBudget"), count: bytes)
            return nil
        case .failure(.encodingFailed):
            PrivacyLog.device(.watch, .surfaceRefused, reason: PrivacyToken("encodingFailed"))
            return nil
        }
    }

    /// Send the phone's status with the surfaces and today folded in
    /// (`WatchApplicationContext.fold`). Skipped, before anything is gathered, for a phone with no
    /// watch or a watch without the app.
    func push() {
        guard session.isActivated, session.isPaired, session.isWatchAppInstalled else { return }
        guard let base = baseContext() else { return }
        lastPushedSet = nil
        let context = WatchApplicationContext.fold(base, surfaces: contextValue(), today: todayValue())
        try? session.updateApplicationContext(context)
        scheduleExpiry()
    }

    /// Push again when the earliest held card expires, so it leaves the wrist on time.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        let expiries = [held.current?.expiresAt, held.route?.expiresAt].compactMap { $0 }
        guard let next = expiries.min() else { return }
        let delay = max(0, next.timeIntervalSince(environment.now())) + 1
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }
}

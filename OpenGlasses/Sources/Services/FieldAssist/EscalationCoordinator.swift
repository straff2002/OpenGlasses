import Foundation

/// Drives the AI → human-expert handoff for a Field Assist session.
///
/// **Phase 3 is architecture-only.** The coordinator runs the full state machine and logs to the
/// session audit, but the live media bridge (`ExpertBridge`) is a `PendingExpertBridge` until
/// Phase 5. When an expert "joins", the flow degrades gracefully: the escalation is recorded and the
/// expert pool is notified (stub), but live video isn't established yet. Swapping in a real
/// `WebRTCExpertBridge` later requires no changes to callers.
@MainActor
final class EscalationCoordinator: ObservableObject {
    static let shared = EscalationCoordinator()

    enum State: Equatable {
        case idle
        case requested(reason: String)
        case awaitingExpert(reason: String)
        case expertConnected(expertId: String)
        case resolved
        case cancelled
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Pluggable so Phase 5 (and tests) can inject real implementations. Defaults to a local
    /// notification plus an optional configured webhook.
    var notifier: ExpertNotifier = CompositeExpertNotifier(notifiers: [
        LocalNotificationExpertNotifier(), WebhookExpertNotifier()
    ])
    var bridge: ExpertBridge = PendingExpertBridge()
    /// The session service the coordinator logs against. Injectable for tests; defaults to shared.
    var sessionService: FieldSessionService = .shared

    // MARK: Named experts (Plan KM P0)

    /// The list of named experts. Empty means today's behaviour: a request pages the pool.
    var expertList: ExpertListStore = .shared
    /// Opens the call route. Injectable so tests never open a URL.
    var placement: CallPlacing = SystemCallPlacement()
    var now: () -> Date = Date.init
    /// Watches the call placed and writes what it saw on the escalation record.
    lazy var callMonitor = ExpertCallMonitor(record: { [weak self] seen in self?.recordSeen(seen) })
    /// The order the last offer gave, for "Sam didn't answer. Try Priya?".
    private(set) var lastPickOrder: [EscalationContact] = []

    init() {}

    var isEscalationActive: Bool {
        switch state {
        case .idle, .resolved, .cancelled, .failed: return false
        case .requested, .awaitingExpert, .expertConnected: return true
        }
    }

    // MARK: - Flow

    /// Request a human expert: record the escalation on the active session, then page the pool.
    ///
    /// Entitlement is checked at this boundary, not only where the button lives — the escalation tool
    /// calls straight in. A revocation observed mid-session stops the *next* escalation; one already
    /// under way runs to `resolve`/`cancel` so the technician is never abandoned on a live call.
    @discardableResult
    func requestExpert(reason: String) async -> State {
        guard FieldAssistEntitlement.shared.has(.fieldWork) else {
            state = .failed("Field Assist isn't unlocked on this device.")
            return state
        }
        state = .requested(reason: reason)
        let service = sessionService
        service.recordEscalation(reason: reason)
        let sessionId = service.activeSession?.id ?? "no-session"
        let assetId = service.activeSession?.assetId

        // Bring up the live stream first (best-effort) so the expert can be handed a join URL.
        try? await bridge.connect(sessionId: sessionId, expertId: nil)
        let roomURL = bridge.roomURL

        do {
            let notified = try await notifier.notifyExpertPool(reason: reason, assetId: assetId, sessionId: sessionId, roomURL: roomURL)
            state = notified ? .awaitingExpert(reason: reason) : .failed("Could not reach any expert.")
        } catch {
            state = .failed(error.localizedDescription)
        }
        return state
    }

    // MARK: - Named experts (Plan KM P0)

    enum CallOutcome: Equatable {
        case placed(EscalationContact, CallVia)
        case refused(String)
    }

    /// Whether any named expert is listed. With none, a request pages the pool as it always has.
    var hasNamedExperts: Bool { !expertList.contacts.isEmpty }

    /// The offer for "get me a furnace expert": the picker over the list, by fixed rules. Nothing
    /// is called and nothing recorded; the offer is a question. Nil with no experts listed.
    func offerExpert(request: String, job: ExpertPicker.Job) -> ExpertPicker.Pick? {
        let experts = expertList.contacts
        guard !experts.isEmpty else { return nil }
        let pick = ExpertPicker.pick(.init(request: request, job: job, experts: experts, now: now(),
                                           lastCalledExpertId: expertList.lastCalledExpertId))
        lastPickOrder = pick.ordered.map(\.contact)
        callMonitor.clearOffer()
        return pick
    }

    /// Call a named expert: open the route, then record the escalation with the expert on it and
    /// move the rota on. The call is the system's — iOS asks the technician to tap Call — so the
    /// outcome says only that the call was started, never that it connected.
    ///
    /// Entitlement is checked here, at the boundary, as `requestExpert` checks it.
    func callExpert(_ contact: EscalationContact, via: CallVia, reason: String) async -> CallOutcome {
        guard FieldAssistEntitlement.shared.has(.fieldWork) else {
            return .refused("Field Assist isn't unlocked on this device.")
        }
        let name = ExpertPicker.spokenName(contact, among: expertList.contacts)
        guard let route = CallRoute.make(contact, via: via) else {
            return .refused(via == .phone
                ? "\(name) has no number on the Experts list that can be dialled."
                : "\(name) has no FaceTime handle or number on the Experts list.")
        }
        guard await placement.place(route) else {
            return .refused("Your phone couldn't start the call to \(name).")
        }
        state = .awaitingExpert(reason: reason)
        sessionService.recordEscalation(reason: reason, expert: contact.snapshot, via: via)
        expertList.lastCalledExpertId = contact.id
        let order = lastPickOrder.contains(where: { $0.id == contact.id }) ? lastPickOrder : [contact]
        callMonitor.expect(contact, order: order)
        return .placed(contact, via)
    }

    /// The offer a call that ended unanswered left, if any.
    var noAnswerOffer: String? { callMonitor.noAnswerOffer }

    /// Write what the monitor saw on the escalation record.
    func recordSeen(_ seen: ExpertCallMonitor.Seen) {
        switch seen.change {
        case .started(let at): sessionService.recordExpertCall(expertId: seen.expertId, started: at)
        case .connected(let at): sessionService.recordExpertCall(expertId: seen.expertId, connected: at)
        case .ended(let at, _): sessionService.recordExpertCall(expertId: seen.expertId, ended: at)
        }
    }

    /// Mark that an expert has joined. Attempts to bring up the live media bridge; in Phase 3 the
    /// bridge is pending, so we still transition to `expertConnected` (the human can act on the
    /// audit record) and report whether live media actually came up.
    @discardableResult
    func markExpertJoined(expertId: String) async -> (state: State, liveMedia: Bool) {
        guard isEscalationActive else { return (state, false) }
        var liveMedia = false
        do {
            try await bridge.connect(sessionId: sessionService.activeSession?.id ?? "no-session", expertId: expertId)
            liveMedia = bridge.isConnected
        } catch {
            PrivacyLog.stream(.expertBridge, .expertBridgeUnavailable, error: SafeErrorSummary(error))
        }
        state = .expertConnected(expertId: expertId)
        return (state, liveMedia)
    }

    /// Resolve the escalation: tear down any live bridge and log resolution on the session.
    func resolve(note: String? = nil) async {
        await bridge.disconnect()
        sessionService.resolveLastEscalation(note: note)
        state = .resolved
    }

    /// Cancel a pending escalation before an expert engages.
    func cancel() async {
        await bridge.disconnect()
        state = .cancelled
    }

    /// End the live view and nothing else: the escalation and the job carry on without it. For a
    /// rule that takes the stream away, as Medical Compliance coming on does.
    func endLiveView() async {
        await bridge.disconnect()
    }

    /// Reset to idle (e.g. when a new session starts).
    func reset() {
        state = .idle
        lastPickOrder = []
    }

    // MARK: - Status

    /// One sentence on whether the expert can see the technician's view, so the tools never
    /// promise live video that didn't come up.
    func liveViewSummary() -> String {
        if ExpertStreamMedicalPolicy.refusesNow { return ExpertStreamMedicalPolicy.liveViewOffSummary }
        return bridge.isConnected
            ? "The live view is being shared with the expert."
            : "Live view didn't start (no live-view relay is set up, or it couldn't be reached), so the expert has the job record."
    }

    /// Human-readable one-line status for tool results / UI.
    func statusSummary() -> String {
        switch state {
        case .idle: return "No escalation active."
        case .requested(let reason): return "Escalation requested: \(reason)"
        case .awaitingExpert(let reason): return "Awaiting a human expert. Reason: \(reason)"
        case .expertConnected(let id): return "Expert \(id) is engaged."
        case .resolved: return "Escalation resolved."
        case .cancelled: return "Escalation cancelled."
        case .failed(let message): return "Escalation issue: \(message)"
        }
    }
}

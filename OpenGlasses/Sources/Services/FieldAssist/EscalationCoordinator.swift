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

    init() {}

    var isEscalationActive: Bool {
        switch state {
        case .idle, .resolved, .cancelled, .failed: return false
        case .requested, .awaitingExpert, .expertConnected: return true
        }
    }

    // MARK: - Flow

    /// Request a human expert: record the escalation on the active session, then page the pool.
    @discardableResult
    func requestExpert(reason: String) async -> State {
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
            NSLog("[Escalation] Live bridge unavailable: %@", error.localizedDescription)
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

    /// Reset to idle (e.g. when a new session starts).
    func reset() {
        state = .idle
    }

    // MARK: - Status

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

import Foundation

/// Live media/data connection to a remote human expert during an escalated Field Assist session.
///
/// **Phase 3 ships the interface only.** The live implementation is deferred to Phase 5, where it
/// will be built over the existing `WebRTCStreamingService` (which already streams the glasses
/// camera to a browser viewer). The escalation state machine references this protocol so the seam
/// is fixed now; swapping `PendingExpertBridge` for a real `WebRTCExpertBridge` later is a one-line
/// change in `EscalationCoordinator`.
///
/// ## Expert-side protocol (v2 sketch)
/// 1. Technician escalates → `ExpertNotifier` pages the expert pool with a join URL (session id token).
/// 2. Expert opens the join URL → a WebRTC offer is exchanged via the signaling server.
/// 3. `ExpertBridge.connect` establishes: outbound = glasses camera + mic; inbound = expert audio.
/// 4. AI stays in the loop, continuing to log the transcript and answer vault lookups on demand.
/// 5. On resolution either side calls `disconnect`; the session audit records the expert id + span.
protocol ExpertBridge {
    /// Whether a live expert media session is currently connected.
    var isConnected: Bool { get }

    /// Establish the live connection for a session. Throws until the Phase 5 implementation lands.
    func connect(sessionId: String, expertId: String?) async throws

    /// Tear down the live connection. Safe to call when not connected.
    func disconnect() async
}

enum ExpertBridgeError: LocalizedError {
    /// The live expert bridge is not available yet (Phase 5).
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Live expert video bridge is not available in this build. The escalation is logged and the expert pool is notified; a human can review the session record."
        }
    }
}

/// Placeholder bridge used until the WebRTC implementation ships in Phase 5.
/// `connect` always throws `.notImplemented`; the escalation flow degrades gracefully to
/// "logged + notified" rather than failing the whole escalation.
struct PendingExpertBridge: ExpertBridge {
    var isConnected: Bool { false }

    func connect(sessionId: String, expertId: String?) async throws {
        throw ExpertBridgeError.notImplemented
    }

    func disconnect() async {}
}

// MARK: - Expert notification

/// Notifies the customer's expert pool when a technician escalates.
///
/// Phase 5 will implement concrete notifiers (push, Slack, email). Phase 3 defines the seam and
/// ships a stub that simulates a successful page so the state machine can be exercised end to end.
protocol ExpertNotifier {
    /// Page the expert pool. Returns true when at least one expert was successfully notified.
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String) async throws -> Bool
}

/// Stub notifier: logs the page and reports success without contacting anyone.
struct StubExpertNotifier: ExpertNotifier {
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String) async throws -> Bool {
        NSLog("[Escalation] (stub) Paging expert pool — session=%@ asset=%@ reason=%@",
              sessionId, assetId ?? "-", reason)
        return true
    }
}

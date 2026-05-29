import Foundation
import UserNotifications

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
@MainActor
protocol ExpertBridge {
    /// Whether a live expert media session is currently connected.
    var isConnected: Bool { get }

    /// Shareable room/join URL the expert opens to view the stream (nil until connected / for stubs).
    var roomURL: String? { get }

    /// Establish the live connection for a session. Throws until the Phase 5 implementation lands.
    func connect(sessionId: String, expertId: String?) async throws

    /// Tear down the live connection. Safe to call when not connected.
    func disconnect() async
}

extension ExpertBridge {
    var roomURL: String? { nil }
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

/// Notifies the customer's expert pool when a technician escalates, handing over the live room URL.
protocol ExpertNotifier {
    /// Page the expert pool. Returns true when at least one channel succeeded.
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool
}

/// Stub notifier: logs the page and reports success without contacting anyone (used by tests).
struct StubExpertNotifier: ExpertNotifier {
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool {
        NSLog("[Escalation] (stub) Paging expert pool — session=%@ asset=%@ reason=%@ room=%@",
              sessionId, assetId ?? "-", reason, roomURL ?? "-")
        return true
    }
}

/// Posts an on-device local notification so the technician (and anyone monitoring the device) sees
/// the escalation immediately. Always available; no backend required.
struct LocalNotificationExpertNotifier: ExpertNotifier {
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Field Assist — expert requested"
        var body = reason
        if let assetId { body += "\nAsset: \(assetId)" }
        if let roomURL { body += "\nJoin: \(roomURL)" }
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "escalation-\(sessionId)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        return true
    }
}

/// POSTs the escalation to a configured webhook (Slack-compatible `{text}` plus structured fields).
/// Returns false when no webhook URL is configured, so a composite can fall back to other channels.
struct WebhookExpertNotifier: ExpertNotifier {
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool {
        let urlString = Config.expertWebhookURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return false }

        var text = "🛠️ Field Assist escalation\nReason: \(reason)\nSession: \(sessionId)"
        if let assetId { text += "\nAsset: \(assetId)" }
        if let roomURL { text += "\nJoin: \(roomURL)" }
        let payload: [String: Any] = [
            "text": text,
            "reason": reason,
            "asset_id": assetId ?? "",
            "session_id": sessionId,
            "room_url": roomURL ?? ""
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }
        return true
    }

    /// Build the webhook payload (exposed for testing).
    static func payload(reason: String, assetId: String?, sessionId: String, roomURL: String?) -> [String: Any] {
        var text = "🛠️ Field Assist escalation\nReason: \(reason)\nSession: \(sessionId)"
        if let assetId { text += "\nAsset: \(assetId)" }
        if let roomURL { text += "\nJoin: \(roomURL)" }
        return ["text": text, "reason": reason, "asset_id": assetId ?? "", "session_id": sessionId, "room_url": roomURL ?? ""]
    }
}

/// Runs several notifiers; succeeds if any channel succeeds (so a missing webhook doesn't fail the page).
struct CompositeExpertNotifier: ExpertNotifier {
    let notifiers: [ExpertNotifier]
    func notifyExpertPool(reason: String, assetId: String?, sessionId: String, roomURL: String?) async throws -> Bool {
        var anySucceeded = false
        for notifier in notifiers {
            if (try? await notifier.notifyExpertPool(reason: reason, assetId: assetId, sessionId: sessionId, roomURL: roomURL)) == true {
                anySucceeded = true
            }
        }
        return anySucceeded
    }
}

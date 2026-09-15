import Foundation

/// The per-backend half of a conversation reset: one adapter per context owner, each going
/// through that backend's own supported API and reporting what it could actually establish.
///
/// Every adapter sits behind a narrow seam rather than the concrete service. The realtime session
/// managers build a `RealtimeAudioEngine` at init and cannot be constructed headlessly, so the
/// seam is what a test drives; the gateway and bridge clients are constructible, and their seams
/// exist so a scripted fake can record what went over the wire.

// MARK: - Realtime sessions (Gemini Live, OpenAI Realtime)

/// A live session whose conversation lives on the far side of a socket.
///
/// Neither service exposes a "forget the conversation" message, so the reset is the session
/// itself: stop it, then start a new one. The stop must also drop anything that would restore
/// the old context on the next connect — `holdsResumableContext` is how that is checked rather
/// than assumed.
@MainActor
protocol RealtimeSessionResetting: AnyObject {
    var isSessionActive: Bool { get }
    /// True while the backend still holds a session-resumption handle — reconnecting with it
    /// would restore the very context the wearer asked to leave. False for backends that have
    /// no resumption concept.
    var holdsResumableContext: Bool { get }
    func stopLiveSession()
    func startLiveSession() async
}

/// Cycles a live session: stop (dropping any resumption handle) then start fresh.
@MainActor
final class RealtimeSessionResetAdapter: ConversationContextResetting {
    let backend: ConversationBackendID
    private let session: any RealtimeSessionResetting

    init(backend: ConversationBackendID, session: any RealtimeSessionResetting) {
        self.backend = backend
        self.session = session
    }

    func resetConversationContext() async -> ConversationResetOutcome {
        // Nothing running means nothing server-side is holding this conversation.
        guard session.isSessionActive else { return .completed(backend) }

        session.stopLiveSession()

        // A handle that survived the teardown would silently resume the old context on the next
        // connect — the one failure mode this adapter exists to prevent, so it fails loudly
        // instead of reconnecting.
        guard !session.holdsResumableContext else {
            return .failed(backend, reason: "the session kept its resumption handle")
        }

        await session.startLiveSession()

        guard session.isSessionActive else {
            return .failed(backend, reason: "the fresh session did not come back up")
        }
        return .completed(backend)
    }
}

// MARK: - Gateway agent

/// A gateway whose conversation is addressed by a session key. Rotating the key is the reset:
/// the old session is left intact on the gateway and nothing further is ever addressed to it.
@MainActor
protocol GatewaySessionResetting: AnyObject {
    var currentSessionKey: String { get }
    func resetSession()
}

@MainActor
final class GatewaySessionResetAdapter: ConversationContextResetting {
    let backend = ConversationBackendID.openClaw
    private let gateway: any GatewaySessionResetting

    init(gateway: any GatewaySessionResetting) {
        self.gateway = gateway
    }

    func resetConversationContext() async -> ConversationResetOutcome {
        let before = gateway.currentSessionKey
        gateway.resetSession()
        guard gateway.currentSessionKey != before else {
            return .failed(backend, reason: "the gateway session key did not rotate")
        }
        // Locally observable and complete: every later request carries the new key, so the old
        // session cannot be addressed again even by a straggler.
        return .completed(backend)
    }
}

// MARK: - Agent bridge

/// A bridge that is told to forget the conversation over its own wire protocol.
@MainActor
protocol BridgeSessionResetting: AnyObject {
    var isBridgeConnected: Bool { get }
    /// Send the protocol's reset frame; false when it could not be sent.
    func sendSessionReset() async -> Bool
}

@MainActor
final class BridgeSessionResetAdapter: ConversationContextResetting {
    let backend = ConversationBackendID.hermes
    private let bridge: any BridgeSessionResetting

    init(bridge: any BridgeSessionResetting) {
        self.bridge = bridge
    }

    func resetConversationContext() async -> ConversationResetOutcome {
        guard bridge.isBridgeConnected else {
            return .failed(backend, reason: "the bridge isn't connected, so it still holds the conversation")
        }
        guard await bridge.sendSessionReset() else {
            return .failed(backend, reason: "the reset could not be sent to the bridge")
        }
        // The bridge protocol has a `session_reset` message but nothing in it correlates one to a
        // request, and a bridge is free never to send it. Reporting this as `completed` would be
        // a guess dressed as a fact.
        return .issuedUnverified(backend, note: "the bridge protocol does not acknowledge a reset")
    }
}

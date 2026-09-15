import Foundation

/// The vocabulary of a conversation reset: who owns the context, what happened to it, and what
/// the wearer is told.
///
/// "New topic" used to mean one thing — wipe `LLMService.conversationHistory` and start a new
/// saved thread. That is only ever the *phone's* copy. A Live session, a realtime session, a
/// gateway agent and a bridge agent each keep their own context on the other side of a socket,
/// and none of them heard the request. These types make "the context was retired" a claim with
/// an owner and an outcome behind it, so the spoken confirmation can only be as strong as what
/// actually happened.

// MARK: - Backends

/// A context owner that a reset has to reach.
///
/// Direct/cloud and local/offline share one owner — both turn shapes read and write the same
/// `LLMService.conversationHistory`, so there is one thing to clear, not two.
enum ConversationBackendID: String, CaseIterable, Equatable {
    /// `LLMService.conversationHistory` — the phone's own turn history (Direct/cloud and
    /// local/offline).
    case phoneHistory
    /// The Gemini Live WebSocket session; context lives server-side for the life of the session.
    case geminiLive
    /// The OpenAI Realtime WebSocket session; conversation items live server-side.
    case openAIRealtime
    /// The gateway agent's session, addressed by a session key.
    case openClaw
    /// The agent bridge's session on the wearer's own network.
    case hermes

    /// How the backend is named out loud. Product names the wearer already sees in Settings —
    /// a confirmation that says "the session" when it means one of four sessions is not honest.
    var spokenName: String {
        switch self {
        case .phoneHistory: return "this conversation"
        case .geminiLive: return "the Gemini Live session"
        case .openAIRealtime: return "the OpenAI Realtime session"
        case .openClaw: return "the gateway agent"
        case .hermes: return "the bridge agent"
        }
    }
}

// MARK: - Outcomes

/// What became of one backend's context.
///
/// `issuedUnverified` is the honest middle: the reset went out over the backend's only supported
/// API, and that protocol has no acknowledgement, so "it worked" would be a guess. It is kept
/// separate from `completed` precisely so the confirmation can be downgraded instead of the
/// distinction being lost.
enum ConversationResetOutcome: Equatable {
    /// The backend confirmed — or the reset is locally observable — that the old context is gone.
    case completed(ConversationBackendID)
    /// The reset was issued through the supported API; the protocol offers nothing to confirm it.
    case issuedUnverified(ConversationBackendID, note: String)
    /// The reset was attempted and did not succeed.
    case failed(ConversationBackendID, reason: String)
    /// The backend exposes no supported way to retire its context.
    case unsupported(ConversationBackendID, reason: String)

    var backend: ConversationBackendID {
        switch self {
        case .completed(let id): return id
        case .issuedUnverified(let id, _): return id
        case .failed(let id, _): return id
        case .unsupported(let id, _): return id
        }
    }

    /// True when everything the protocol allows was done. `issuedUnverified` counts: refusing to
    /// reset a backend that simply never acknowledges anything would strand the wearer in a
    /// conversation they asked to leave.
    var crossedBoundary: Bool {
        switch self {
        case .completed, .issuedUnverified: return true
        case .failed, .unsupported: return false
        }
    }

    /// The fixed vocabulary token for the privacy log — never the reason string, which can quote
    /// a server.
    var logToken: String {
        switch self {
        case .completed: return "completed"
        case .issuedUnverified: return "issuedUnverified"
        case .failed: return "failed"
        case .unsupported: return "unsupported"
        }
    }
}

// MARK: - Adapters

/// One backend's reset, behind its own supported API.
///
/// Adapters are the only place that knows *how* a backend retires context — rotate a session key,
/// cycle a socket, clear an array. The coordinator knows only that it asked and what came back.
@MainActor
protocol ConversationContextResetting: AnyObject {
    var backend: ConversationBackendID { get }
    func resetConversationContext() async -> ConversationResetOutcome
}

// MARK: - Request and report

/// Where a reset came from. Every entry point is one of these three — there is no fourth router.
enum ConversationResetSource: String, Equatable {
    /// The classifier's Tier-0 route for a bare reset phrase ("new topic").
    case voiceCommand
    /// The model called the `new_topic` tool mid-turn.
    case modelToolCall
    /// The conversation UI's new-conversation action.
    case userInterface
}

/// What one reset run did, end to end.
struct ConversationResetReport: Equatable {
    let source: ConversationResetSource
    /// The generation this reset established. Output tagged with anything older is stale.
    let generation: UInt64
    /// One entry per backend in the plan, in the order they were reset.
    let outcomes: [ConversationResetOutcome]
    /// Whether the phone's history was cleared and a new saved thread started. False whenever any
    /// backend held out — the phone's display must never be the only thing that changed.
    let didRetireLocalContext: Bool

    /// Backends that were asked and did not cross the boundary.
    var heldBack: [ConversationBackendID] {
        outcomes.filter { !$0.crossedBoundary }.map(\.backend)
    }

    /// Backends that were reset through a protocol that cannot confirm it.
    var unverified: [ConversationBackendID] {
        outcomes.compactMap { if case .issuedUnverified(let id, _) = $0 { return id } else { return nil } }
    }

    var isFullySuccessful: Bool {
        didRetireLocalContext && heldBack.isEmpty && unverified.isEmpty
    }
}

// MARK: - Spoken copy

/// The confirmation the wearer hears, derived from what actually happened.
///
/// Pure, so the honesty rule — never confirm success after only clearing the phone's display —
/// is a unit test rather than a promise.
enum ConversationResetCopy {

    static func confirmation(for report: ConversationResetReport) -> String {
        let held = report.heldBack
        guard report.didRetireLocalContext else {
            guard !held.isEmpty else {
                return "I couldn't start a fresh conversation just now."
            }
            return "I couldn't clear \(list(held)), so I've left this conversation as it is."
        }
        let unverified = report.unverified
        if unverified.isEmpty {
            return "Okay — fresh start. What would you like to talk about?"
        }
        return "Fresh start. I asked \(list(unverified)) to forget the conversation too, "
            + "but it doesn't confirm resets."
    }

    /// "the gateway agent", "the gateway agent and the bridge agent", "a, b and c".
    private static func list(_ backends: [ConversationBackendID]) -> String {
        let names = backends.map(\.spokenName)
        switch names.count {
        case 0: return "anything"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}

// MARK: - Turn boundary

/// The barrier a reset waits on before it retires anything.
///
/// A reset requested *inside* a turn — the model called `new_topic` while a tool result is still
/// owed — must not wipe the context that turn is still using: the pending `tool_result` would be
/// orphaned and the next request rejected, and a gateway key rotated mid-run would post the tool's
/// answer to a session that no longer exists. So the coordinator waits for the turn to finish
/// first. Polled rather than signalled because "busy" is the union of two independent flags
/// (`LLMService.isProcessing` and the app's own turn state) that no single service owns; bounded
/// so a wedged turn delays the reset instead of cancelling it.
@MainActor
enum ConversationTurnBoundary {

    /// Returns true if the turn ended within the deadline, false if the deadline won.
    @discardableResult
    static func wait(isBusy: () -> Bool,
                     timeout: TimeInterval = 20,
                     pollInterval: TimeInterval = 0.05,
                     now: () -> Date = Date.init,
                     sleep: (TimeInterval) async -> Void = {
                         try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                     }) async -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while isBusy() {
            guard now() < deadline else { return false }
            await sleep(pollInterval)
        }
        return true
    }
}

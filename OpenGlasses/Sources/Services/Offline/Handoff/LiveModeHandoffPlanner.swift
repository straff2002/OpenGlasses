import Foundation

/// The live modes' half of the offline handoff (Plan GE P3).
///
/// Gemini Live and OpenAI Realtime run over a socket. When it drops, `LiveRecoveryDriver` retries;
/// once the retries are exhausted the session used to end with "I couldn't reconnect" and the
/// conversation stopped there. With the handoff on and the signal really gone, the conversation
/// carries on on the phone instead — through Direct mode's on-device path, which already hears,
/// thinks and speaks without the network — and when a stable connection returns the live session
/// is started again, opening with a ``LiveContextHandover`` block built from the turns the phone
/// answered, so the wearer does not have to repeat themselves.
///
/// The phone-side session for a live mode is Direct mode's handoff rather than a separate
/// camera-grounded loop: one offline path to keep honest instead of two. A camera-grounded
/// on-device loop (`LiveSessionTurnLoop` and its assembler) remains the foreground upgrade once its
/// latency is measured on a device.
///
/// Pure: what the app is doing comes in as values.
enum LiveModeHandoffPlanner {

    enum LossDecision: Equatable {
        /// Carry on on the phone; resume this live mode when the connection is back.
        case continueOnPhone(resume: AppMode)
        /// End the session as before.
        case endSession
    }

    /// A live session gave up reconnecting.
    /// - Parameters:
    ///   - mode: the mode that lost its session.
    ///   - handoffEnabled: the setting's effective value.
    ///   - route: where the handoff says the conversation is.
    ///   - pathSatisfied: whether the network path claims to be up.
    static func decideOnLoss(mode: AppMode, handoffEnabled: Bool, route: HandoffRoute,
                             pathSatisfied: Bool) -> LossDecision {
        guard mode.isRealtime, handoffEnabled else { return .endSession }
        // Only a loss the network explains is handed to the phone. A session that died with the
        // path up and the cloud reachable is a provider problem, and the phone would not fix it.
        guard route == .phone || !pathSatisfied else { return .endSession }
        return .continueOnPhone(resume: mode)
    }

    /// Back on the cloud: the live mode to restart, or nil. Nothing restarts when the wearer moved
    /// on in the meantime — switched to another live mode, or already started one.
    static func modeToResume(pending: AppMode?, currentMode: AppMode, liveSessionActive: Bool) -> AppMode? {
        guard let pending, pending.isRealtime, currentMode == .direct, !liveSessionActive else { return nil }
        return pending
    }

    /// The handover block a resumed session opens with, from the turns answered on the phone
    /// (oldest first, as `(role, content)` with "user"/"assistant" roles). Nil when there are none.
    static func resumeContext(phoneTurns: [(role: String, content: String)]) -> String? {
        let records = phoneTurns.compactMap { turn -> LiveTurnRecord? in
            switch turn.role {
            case "user": return LiveTurnRecord(speaker: .wearer, text: turn.content)
            case "assistant": return LiveTurnRecord(speaker: .assistant, text: turn.content)
            default: return nil
            }
        }
        return LiveContextHandover.build(turns: records)
    }
}

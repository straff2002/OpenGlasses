import Foundation

/// Whether the reconnect ladder may climb another rung, and what to do when it may not.
///
/// The delays themselves stay in `StreamRecoveryPolicy` — this is the *gate* in front of them, and
/// it exists because the backend used to answer four different questions with one `guard`:
///
/// * Does anybody still want the stream? (intent)
/// * Is something of ours already rebuilding it? (ownership — two rebuilders racing for one
///   process-wide camera capability is how a dropped stream becomes `capabilityAlreadyActive`)
/// * Can a retry succeed at all, given what the SDK last said went wrong? (compatibility vs
///   transient — this one was never asked)
/// * Is the budget spent?
///
/// Pure, so each answer is a row in a table rather than a shape in a 1200-line file.
enum StreamReconnectPolicy {

    enum Decision: Equatable {
        /// Climb this rung after `delay`.
        case retry(after: TimeInterval, attempt: Int)
        /// A start or rebuild we own is in flight. Re-check after `delay` **without consuming a
        /// rung**: the budget is for the glasses being unreachable, not for waiting out our own
        /// warm-up, and spending it here is how a healthy cold start could exhaust the ladder.
        case deferToOwner(after: TimeInterval)
        /// Nobody wants the stream any more. Schedule nothing, say nothing — a stop is an ending,
        /// and the wearer already knows they pressed it.
        case standDown
        /// Stop retrying and say why. Either the budget is spent, or the last failure is one that
        /// no number of retries can clear.
        case giveUp(notice: String)
    }

    /// How long to wait before looking again while somebody else owns the stream. Short, because
    /// the thing being waited on is a warm-up or a rebuild that reports its own outcome.
    static let deferToOwnerDelay: TimeInterval = 1

    /// - Parameters:
    ///   - attempt: which rung of `StreamRecoveryPolicy.reconnectDelay` is next (0-based).
    ///   - streamingIntended: continuous streaming is still wanted.
    ///   - transitionIsOurs: a warm-up, a stall recovery or a capture already owns the stream.
    ///   - lastFailure: what the SDK last said went wrong, classified. `nil` when the stream simply
    ///     stopped without an error — the ordinary link drop, which is exactly what the ladder is
    ///     for.
    static func next(attempt: Int,
                     streamingIntended: Bool,
                     transitionIsOurs: Bool,
                     lastFailure: CameraErrorPolicy.RetryDisposition?) -> Decision {
        // Intent first, and the order is load-bearing: a stream nobody wants must not be retried
        // even when the error says a retry would work, and must not produce a give-up notice about
        // a camera the wearer deliberately switched off.
        guard streamingIntended else { return .standDown }
        if transitionIsOurs { return .deferToOwner(after: deferToOwnerDelay) }
        if case .stopRetrying(let notice) = lastFailure { return .giveUp(notice: notice) }
        guard let delay = StreamRecoveryPolicy.reconnectDelay(attempt: attempt) else {
            return .giveUp(notice: StreamRecoveryPolicy.reconnectGaveUpNotice)
        }
        return .retry(after: delay, attempt: attempt)
    }

    /// Whether a rung that has already been scheduled may still act when it wakes up.
    ///
    /// A rung sleeps for up to five seconds. In that window the wearer can stop the camera, a
    /// live session can end, the stream can come back on its own, or the whole camera session can
    /// be replaced — and a ladder that only re-checked its intent would happily start a stream
    /// belonging to a session that no longer exists. So the generation is re-checked too: it is
    /// bumped by every stop, and a rung whose generation has moved is a rung of a ladder that was
    /// climbing a different camera.
    static func mayAct(streamingIntended: Bool,
                       alreadyStreaming: Bool,
                       scheduledUnderSession: Int,
                       currentSession: Int) -> Bool {
        streamingIntended && !alreadyStreaming && scheduledUnderSession == currentSession
    }
}

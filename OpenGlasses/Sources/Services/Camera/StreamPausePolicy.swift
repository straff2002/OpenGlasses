import Foundation

/// What the app may do about a **paused** glasses video stream — and, as a type rather than a
/// convention, what it may not.
///
/// # The discrepancy this resolves
///
/// Two rules lived in the repository at once and contradicted each other.
///
/// * `StreamRecoveryPolicy.shouldRecoverFromStall` states, in code and in prose, that `.paused` is
///   a **system hold**: frames stopping is the expected behaviour, *there is no app-callable
///   resume*, and tearing the stream down collapses the media channel the hold would otherwise
///   resume from. The session-cleanup acceptance criteria say the same thing — a paused session is
///   retained and never triggers a competing restart.
/// * `MetaCameraBackend`'s state listener answered a wanted pause by calling `Stream.start()`
///   immediately, and the warm-up wait treated `.paused` exactly like `.stopped`, nudging
///   `start()` up to three times before giving up.
///
/// The pinned SDK settles it. `MWDATCamera.Stream` exposes `start()`, `stop()`, `state`,
/// `statePublisher`, `videoFramePublisher`, `photoDataPublisher`, `errorPublisher` and
/// `capturePhoto(format:)` — nothing else. `StreamState` carries `.paused` with **no transition
/// out of it that the app can call**, and `MWDATCore.DeviceSession` is the same shape: `start()`,
/// `stop()`, a `.paused` state, no resume. There is therefore no documented same-session resume
/// API, and `start()` on a paused stream is not a sanctioned resume — it is a second start issued
/// against a session the system is already holding.
///
/// What our own device traces recorded points the same way. Every observed cause of a pause is
/// physical and is cleared physically: the temple-tap hold (the wearer's own hold, resumed by the
/// wearer's next tap), a doff — which since DAT 0.9 pauses the stream — and folded hinges. None of
/// them is a fault the app can repair, and the notice the wearer sees already names the move that
/// does repair it.
///
/// # The rule
///
/// **A pause is waited out, never started out of.** The app reports it, keeps the paused session
/// and its resources exactly as they are, schedules nothing, and lets the SDK move the stream. The
/// resume is then observed like any other state change and the streaming claim is restored from it.
///
/// The prohibition is enforced by shape, not by discipline: `PauseResponse` has no case that issues
/// a start, so a caller applying this policy cannot express the old behaviour. `WarmupAction` is
/// the one place a `start()` may still be issued, and it is reachable only from `.stopped` — the
/// cold-start churn a start really does recover from.
enum StreamPausePolicy {

    // MARK: - A pause, while streaming is still wanted

    /// What to do about a stream that has gone `.paused`.
    ///
    /// Deliberately missing a `resume`/`start` case. That absence is the policy: there is nothing
    /// to call, so there is nothing to express.
    enum PauseResponse: Equatable {
        /// Report the pause and wait for the SDK to move the stream itself. The session, the
        /// listeners and the camera capability all stay exactly as they are.
        case awaitSDKResume(notice: String)
        /// A pause nobody is waiting on — the app parked the stream itself after a one-off
        /// capture, say. Saying anything here would train the wearer to ignore the notice that
        /// matters.
        case staySilent
    }

    static func response(streamingIntended: Bool) -> PauseResponse {
        streamingIntended ? .awaitSDKResume(notice: CameraStreamStatePolicy.pausedNotice)
                          : .staySilent
    }

    /// The same decision expressed over `CameraStreamStatePolicy`'s table, so the two cannot drift:
    /// whatever that policy decides about a `.paused` stream, this is what the backend does with it.
    static func response(to decision: CameraStreamStatePolicy.Decision) -> PauseResponse? {
        guard case .pausedWhileWanted(let notice) = decision else { return nil }
        return .awaitSDKResume(notice: notice)
    }

    // MARK: - Waiting for a start to reach `.streaming`

    /// What a start-side waiter should do about the state it is looking at.
    enum WarmupAction: Equatable {
        /// `.streaming` — the wait is over.
        case ready
        /// Transient churn, or a hold we are not allowed to touch. Keep waiting.
        case wait
        /// A cold start bounces through `.stopped` for 15–18 s on its way up, and a start that
        /// landed in the gap really is recovered by another `start()`. The only case that issues
        /// one.
        case nudgeStart(attempt: Int)
        /// Stop waiting. A start cannot fix either of these.
        case giveUp(GiveUpReason)
    }

    enum GiveUpReason: Equatable {
        /// The SDK has held the stream paused for longer than a moment. A start cannot lift a
        /// hold, and sitting out the full warm-up timeout for one just delays the honest answer.
        case pauseHeld
        /// The nudges a cold start is allowed are spent; the stream needs rebuilding, which only
        /// the caller can do.
        case nudgesSpent
    }

    /// How long a pause may stand during a *start* before the start gives up on it.
    ///
    /// Shorter than the warm-up timeout on purpose: the wearer is waiting on a camera that the
    /// system is holding, and the fix — put the glasses on, open the hinges, tap the temple — is
    /// theirs and is quick. Long enough that a pause the SDK clears on its own is simply waited out.
    static let pauseHoldGrace: TimeInterval = 5

    /// How many `start()` nudges a cold start may issue while the stream sits at `.stopped`.
    static let maxColdStartNudges = 3

    /// - Parameters:
    ///   - state: the stream state observed right now.
    ///   - pausedFor: how long the stream has been continuously `.paused`, or `nil` if it is not.
    ///   - nudgesUsed: how many nudges this wait has already issued.
    static func warmupAction(state: CameraStreamStatePolicy.StreamState,
                             pausedFor: TimeInterval? = nil,
                             nudgesUsed: Int = 0,
                             maxNudges: Int = maxColdStartNudges) -> WarmupAction {
        switch state {
        case .streaming:
            return .ready
        case .paused:
            // Never a nudge. A paused stream is held by the system, and a start issued into a hold
            // is the competing restart this whole policy exists to remove.
            return (pausedFor ?? 0) >= pauseHoldGrace ? .giveUp(.pauseHeld) : .wait
        case .stopped:
            return nudgesUsed < maxNudges ? .nudgeStart(attempt: nudgesUsed + 1)
                                          : .giveUp(.nudgesSpent)
        case .starting, .stopping, .waitingForDevice:
            return .wait
        }
    }

    // MARK: - The resume

    /// Whether a `.streaming` state that arrives with continuous streaming still wanted should
    /// restore the streaming claim the pause (or the drop) cleared.
    ///
    /// The other half of the rule, and the half that was missing entirely: with no nudge, the
    /// SDK's own resume is the *only* way back, so it has to be acted on. Before this, a doff and
    /// a re-don left `isStreaming` false for the rest of the session — which also left the stall
    /// detector disarmed, since it guards on exactly that flag — while frames flowed and the UI
    /// said the camera was waiting.
    ///
    /// - Parameters:
    ///   - streamingIntended: continuous streaming is still wanted.
    ///   - alreadyStreaming: the app already believes the stream is up.
    ///   - transitionIsOurs: a start or rebuild we own is in flight. Those own their own commit —
    ///     a warm-up in particular must be allowed to find its start superseded and release it, so
    ///     it must not have the stream published as running out from under it.
    static func restoresStreamingClaim(streamingIntended: Bool,
                                       alreadyStreaming: Bool,
                                       transitionIsOurs: Bool) -> Bool {
        streamingIntended && !alreadyStreaming && !transitionIsOurs
    }
}

import Foundation

/// Plan FF P1/PR5 — what a reconnect actually restored, as four independent facts.
///
/// # The claim this replaces
///
/// "Reconnected" was one boolean standing in for four different things, and each of the four can be
/// false on its own:
///
/// * the **socket** came back — the only one the transport can see;
/// * the **microphone** restarted — PR2 made this audible, because a connected session with a dead
///   microphone invites the wearer to talk into a void;
/// * **visual evidence** is arriving again — a camera that paused during the outage leaves the
///   session able to hear and unable to see, and a blind wearer asking "what's in front of me"
///   needs to know that before they ask;
/// * the **conversation's thread** survived — the one this phase adds. Resumption restores it; a
///   rejected or expired handle does not, and a locally rebuilt handover restores some of it.
///
/// Collapsing them is what produces the cheerful lie. Keeping them apart is what lets the spoken
/// line say which of the four is missing.
///
/// Pure. The recording and the spoken delivery live elsewhere; this only decides what is true.
struct LiveRecoveryAssessment: Equatable {

    /// What became of the conversation itself.
    enum ContextContinuity: Equatable {
        /// The server took the resumption handle and handed the conversation back. Nothing was lost.
        case resumed
        /// The server would not (or could not) resume, and the phone put its own bounded record of
        /// the last turns in front of the new session instead. Partial, and honest about being so.
        case rebuilt(turns: Int)
        /// Neither. The new session starts with no idea what was being discussed.
        case lost

        /// Whether the session can honestly refer back to what was being talked about.
        ///
        /// `rebuilt(turns: 0)` is not a thing this type produces — a handover with no turns is
        /// `lost` — but the guard is written anyway so the property cannot become a lie by
        /// someone constructing one.
        var carriesPriorContext: Bool {
            switch self {
            case .resumed: return true
            case .rebuilt(let turns): return turns > 0
            case .lost: return false
            }
        }
    }

    /// The transport finished setup and can carry a turn.
    let socketReady: Bool
    /// Microphone capture restarted without throwing.
    let microphoneRestored: Bool
    /// A decoded picture from *this* camera session, newer than the evidence window
    /// (`CameraReadiness.hasFreshVisualEvidence`), **read at the moment of assessment**.
    ///
    /// Right after a reconnect that is usually `false` by construction — no frame has had time to
    /// arrive. That is exactly why `AudibleLifecycleCoordinator` waits out its own bounded window
    /// before deciding the cue: this records what was true when the recovery finished, and the
    /// coordinator's delivered notice is the authority on what the wearer is told.
    let visualEvidenceFresh: Bool
    /// Whether this session answers questions about what the wearer is looking at. An audio-only
    /// session is not degraded by a camera that is not running.
    let needsVisualEvidence: Bool
    let contextContinuity: ContextContinuity

    init(socketReady: Bool,
         microphoneRestored: Bool,
         visualEvidenceFresh: Bool,
         needsVisualEvidence: Bool,
         contextContinuity: ContextContinuity) {
        self.socketReady = socketReady
        self.microphoneRestored = microphoneRestored
        self.visualEvidenceFresh = visualEvidenceFresh
        self.needsVisualEvidence = needsVisualEvidence
        self.contextContinuity = contextContinuity
    }

    /// Whether the camera can answer a question right now — trivially true for a session that does
    /// not need to see.
    var visionUsable: Bool { !needsVisualEvidence || visualEvidenceFresh }

    /// Whether every fact this session depends on came back.
    var isCompleteRecovery: Bool {
        socketReady && microphoneRestored && visionUsable && contextContinuity.carriesPriorContext
    }

    /// The evidence the audible lifecycle decides its cue from. The translation is one-way on
    /// purpose: this type is the record of what happened, that one is the input to what is said.
    var recoveryEvidence: AudibleLifecyclePolicy.RecoveryEvidence {
        AudibleLifecyclePolicy.RecoveryEvidence(
            audioRestored: microphoneRestored,
            needsVisualEvidence: needsVisualEvidence,
            hasFreshVisualEvidence: visualEvidenceFresh,
            contextCarried: contextContinuity.carriesPriorContext)
    }

    /// What these facts alone imply. Not necessarily what is said: see `visualEvidenceFresh`.
    var notice: AudibleLifecyclePolicy.Notice {
        AudibleLifecyclePolicy.recoveryNotice(for: recoveryEvidence)
    }

    // MARK: - Deriving continuity

    /// Decide continuity from what the transport and the handover between them achieved.
    ///
    /// The order matters: a server that resumed the session makes the local handover irrelevant,
    /// and a handover with nothing in it is `lost` rather than a `rebuilt` claim over an empty
    /// record — "I'm back; the last thing we were on was …" may only be said when there is a last
    /// thing.
    static func continuity(resumedOnServer: Bool, handoverTurns: Int) -> ContextContinuity {
        if resumedOnServer { return .resumed }
        return handoverTurns > 0 ? .rebuilt(turns: handoverTurns) : .lost
    }
}

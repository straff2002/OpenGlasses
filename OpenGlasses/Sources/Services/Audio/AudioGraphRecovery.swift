import Foundation

/// What to do with a realtime audio graph that an OS event, or our own scheduling path, has just
/// found in a questionable state (Plan CW P1).
///
/// Distinct from `AudioRecoveryAction`, which answers the *session*-level question ("pause / resume
/// / the route moved"). This answers the narrower one that comes after: given what the graph
/// actually looks like right now, does it need rebuilding, or only starting?
enum AudioGraphAction: Equatable {
    /// The graph is intact and running, or we aren't capturing. Leave it alone.
    case none
    /// The nodes are still wired and only the engine stopped — `start()` is sufficient, and
    /// crucially it leaves every already-scheduled playback buffer in place.
    case restart
    /// The graph must be torn down and re-established. `carryPlayback` is whether the buffers
    /// scheduled on the old player node can be re-scheduled onto the new one (Plan CW P2); `false`
    /// means they are unplayable on the new graph and must be **reported as lost**, never silently
    /// dropped.
    case rebuild(carryPlayback: Bool)
}

/// What prompted the question. Carried for logging and for the field measurement Plan CW P4 owes —
/// the restart-vs-rebuild ratio is only interpretable per trigger.
enum AudioGraphTrigger: String, Equatable, CaseIterable {
    /// An `AVAudioSession.routeChangeNotification` the session policy classified as `.resetGraph`.
    case routeChange
    /// An interruption ended and resuming the engine failed.
    case interruptionEnded
    /// The playback path found the engine dead with audio in hand to schedule.
    case schedulingDiscovery
}

/// The observed state of the engine graph at the moment recovery is considered.
///
/// Every field is something the caller reads off the live `AVAudioEngine` on its lifecycle queue,
/// which is exactly why the *decision* is extracted: none of these combinations can be produced in
/// a test process, and three of the four have never been exercised.
struct AudioGraphState: Equatable {
    /// `audioEngine.isRunning`.
    var engineRunning: Bool
    /// The player node is still attached and the input tap still installed — i.e. the graph is
    /// wired, whatever the engine is doing.
    var nodesAttached: Bool
    /// The input node's format no longer matches the one the tap and converter were built for.
    var formatChanged: Bool
    /// Whether we still intend to be capturing. Mirrors the existing `isCapturing` guard.
    var isCapturing: Bool
}

/// Decides restart-vs-rebuild for a realtime audio graph.
///
/// This exists because the two paths that meet a stopped engine disagreed. `playAudioOnQueue`
/// restarts it and keeps the queued reply; the *recovery* path tore the whole graph down and
/// discarded that reply — and a Bluetooth mic coming up at session start looks like
/// `.newDeviceAvailable`, so the reply most likely to be destroyed was the **first one of the
/// session**. One decision function, four rules, both paths.
///
/// The trigger deliberately does **not** change the answer today. Plan CW's open question — whether
/// `.newDeviceAvailable` should still force a graph reset once `.restart` exists, or whether the
/// format check subsumes it — is not answerable from a desk, so rather than guess at a per-trigger
/// branch we made the table trigger-invariant and record the trigger so P4's field data can settle
/// it. `triggerInvariance` in the tests pins that, so a future branch has to be deliberate.
enum AudioGraphRecovery {

    /// - Parameters:
    ///   - trigger: what prompted the check (does not affect the outcome — see the type note).
    ///   - state: the observed graph state.
    static func action(for trigger: AudioGraphTrigger, state: AudioGraphState) -> AudioGraphAction {
        // Not capturing: the same guard every existing recovery path already applies. A route
        // change while idle is somebody else's problem.
        guard state.isCapturing else { return .none }

        // Format change wins over everything. A tap and a converter built for 48 kHz phone input
        // produce garbage on an 8 kHz HFP link, so restarting into a stale format is worse than
        // rebuilding — and the scheduled playback buffers no longer match the graph they were
        // built for, so they cannot be carried and must be accounted as lost instead.
        if state.formatChanged { return .rebuild(carryPlayback: false) }

        // The graph really is broken. Rebuild — but the pending reply still must not evaporate.
        if !state.nodesAttached { return .rebuild(carryPlayback: true) }

        // Nodes wired, format unchanged, engine merely stopped: this is the session-start settle,
        // and the whole point of the plan. `start()` is enough and the queued reply survives.
        if !state.engineRunning { return .restart }

        return .none
    }

    /// Whether an input format differs from the one the tap was built for, in the only two
    /// dimensions that invalidate a tap and its converter.
    ///
    /// Sample rates are compared with a tolerance because hardware reports them as `Double` and a
    /// route can re-report the *same* rate with a sub-Hz difference; treating that as a change
    /// would rebuild the graph — destroying playback — over a rounding artefact. Anything that
    /// actually matters here (48000 → 8000, 24000 → 16000) is orders of magnitude clear of it.
    static func formatChanged(
        fromSampleRate: Double, fromChannels: UInt32,
        toSampleRate: Double, toChannels: UInt32
    ) -> Bool {
        if fromChannels != toChannels { return true }
        return abs(fromSampleRate - toSampleRate) > 1.0
    }
}

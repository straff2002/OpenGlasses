import Foundation

/// Whether a start was asked for by someone — the wearer, a screen, a tool — or by the service
/// itself recovering from an OS event.
///
/// The distinction decides one thing only: whether a deliberate pause blocks the start. A route
/// change or an ended interruption must not barge in on capture another consumer is holding, but
/// the owner that paused it says so by asking explicitly.
enum ListenerStartOrigin: String, Equatable, CaseIterable {
    /// A caller asked for listening: `startListening()`.
    case explicit
    /// The service asked itself: route change, interruption ended, recognition restart, resume.
    case automatic
}

/// What the recognizer is actually doing, as opposed to what a flag claims.
///
/// `ended` is the case the old single-flag guard could not see. A `SFSpeechRecognitionTask` that
/// has finished or been cancelled leaves the audio engine running and the tap installed, so every
/// "is the engine up?" check passes while nothing on earth is recognising speech.
enum ListenerRecognitionState: Equatable {
    /// No task exists.
    case none
    /// A task exists and is running (or starting).
    case running
    /// A task existed and has finished, completed or been cancelled. `failed` records whether its
    /// last callback carried an error; it is logged, never branched on — an ended recognizer is
    /// broken listening either way, and pinning that keeps a future branch deliberate.
    case ended(failed: Bool)
}

/// The listener's audio graph as it can actually be observed: what the engine, the tap and the
/// recognition task are doing right now.
///
/// Separated from the rest of the health inputs because this is the part that only exists on a
/// device. A simulator has no microphone route and no real recognizer, so the snapshot is what the
/// tests substitute; every rule below is expressed over it.
struct ListenerGraphSnapshot: Equatable {
    /// `audioEngine?.isRunning == true`.
    var engineRunning: Bool
    /// The input tap is installed on bus 0 — the graph is wired, whatever the engine is doing.
    var tapInstalled: Bool
    /// What the recognition task is doing.
    var recognition: ListenerRecognitionState

    init(engineRunning: Bool = false,
         tapInstalled: Bool = false,
         recognition: ListenerRecognitionState = .none) {
        self.engineRunning = engineRunning
        self.tapInstalled = tapInstalled
        self.recognition = recognition
    }
}

/// A pause somebody took on purpose, which must not be mistaken for a fault.
enum ListenerPauseReason: String, Equatable, CaseIterable {
    /// The running engine was handed to another consumer (dictation, captions) and the wake-word
    /// recognizer was torn down so the two do not fight over the microphone.
    case sharedEngine
    /// Sustained silence — the glasses are most likely in their case.
    ///
    /// Recorded, but deliberately **not** a reason to refuse a start: the only signal that ends a
    /// silence pause is audio arriving, and audio only arrives while the listener runs. Refusing
    /// on it would make the pause feed itself.
    case silence
}

/// Why a start was declined outright.
enum ListenerRefusal: String, Equatable, CaseIterable {
    /// Push-to-talk. The always-on listener never runs in this mode; on-demand capture still does.
    case silentMode
    /// Nobody wants listening. Either it was never asked for, or an explicit stop withdrew it —
    /// and an explicit stop is not undone by a route change.
    case noIntent
    /// Microphone or speech-recognition authorization was refused.
    case noPermission
}

/// Why the listener has to be rebuilt rather than merely started.
enum ListenerBreakReason: String, Equatable, CaseIterable {
    /// The flag says listening and the engine has stopped. This is the shape the field report
    /// took: after an audio disruption the flag stayed `true`, so every later auto-start returned
    /// at the guard and no listener was ever rebuilt.
    case engineStopped
    /// The engine is running but recognition has ended. Engine running alone does not prove
    /// recognition works — this rule is the whole reason the decision reads more than one input.
    case recognitionEnded
    /// The flag says listening and no recognition task exists at all.
    case noRecognitionTask
    /// The engine is running with no tap: nothing is feeding the recognizer or the other
    /// consumers, so buffers are going nowhere.
    case tapMissing
    /// A recognition task survives an engine that is gone. Its callbacks are obsolete and its
    /// request is fed by nothing.
    case staleRecognitionTask
}

/// Everything the health decision is allowed to look at.
struct ListenerHealthState: Equatable {
    /// `isListening` — what the service currently claims. Carried because a claim that disagrees
    /// with the graph is itself evidence, never because it is trusted on its own.
    var flagSaysListening: Bool
    /// The observed audio graph.
    var graph: ListenerGraphSnapshot
    /// Another consumer is deliberately feeding off the shared tap (dictation, captions, rewind,
    /// diarization). They survive a rebuild — the forwarder set is re-published into the new tap —
    /// but they are the reason a *deliberate* pause is not a fault.
    var captureShared: Bool
    /// A pause taken on purpose, if one is in force.
    var deliberatelyPaused: ListenerPauseReason?
    /// The audio-session lease is held. Carried so the decision can be logged against ownership;
    /// recovery never releases or re-acquires it, so it does not change the answer.
    var leaseHeld: Bool
    /// Somebody wants listening. Withdrawn only by an explicit stop; a pause keeps it.
    var intent: Bool
    /// Push-to-talk (silent mode).
    var silentMode: Bool
    /// Authorization, which is not known until it has been asked for — hence `unknown`, which the
    /// pre-flight pass uses so the cheap answers (healthy, refused, paused) can be given before
    /// anything is awaited.
    var permission: Permission
    /// Who asked.
    var origin: ListenerStartOrigin

    enum Permission: String, Equatable, CaseIterable { case granted, denied, unknown }

    init(flagSaysListening: Bool = false,
         graph: ListenerGraphSnapshot = ListenerGraphSnapshot(),
         captureShared: Bool = false,
         deliberatelyPaused: ListenerPauseReason? = nil,
         leaseHeld: Bool = false,
         intent: Bool = true,
         silentMode: Bool = false,
         permission: Permission = .unknown,
         origin: ListenerStartOrigin = .explicit) {
        self.flagSaysListening = flagSaysListening
        self.graph = graph
        self.captureShared = captureShared
        self.deliberatelyPaused = deliberatelyPaused
        self.leaseHeld = leaseHeld
        self.intent = intent
        self.silentMode = silentMode
        self.permission = permission
        self.origin = origin
    }
}

/// What a start request should do.
enum ListenerHealthDecision: Equatable {
    /// A working listener is already up. Keep it; the request is satisfied by the listener that
    /// exists, which is what "coalesce" means for a caller that only wants to be listening.
    case healthy
    /// Somebody paused this on purpose and will resume it themselves. Do not rebuild.
    case pausedDeliberately(ListenerPauseReason)
    /// Listening is broken. Tear the graph down through the existing cleanup, then start
    /// recognition again — same engine ownership, same lease.
    case rebuild(ListenerBreakReason)
    /// Nothing is up and nothing is broken. Start recognition; reuse a running engine if there
    /// is one, which is how a shared-engine handoff comes back without disturbing its consumers.
    case startFresh
    /// Do not start.
    case refuse(ListenerRefusal)
}

/// Decides whether the wake-word listener is healthy, deliberately idle, or broken.
///
/// # Why this exists
///
/// `startListening()` used to open with `guard !isListening else { return }`, and that flag was
/// the only health check in the service. Every auto-start path in the app funnels through it, so a
/// flag left `true` by an audio disruption — an interruption, a route flap, a recognizer that
/// ended on its own — turned all of them into silent no-ops. The service reported that it was
/// listening while nothing was recognising, and the only cure in the field was relaunching.
///
/// The fix is not a better flag. It is asking the graph. The rules below read the engine, the tap
/// and the recognition task together, because each of them can be fine while the listener as a
/// whole is dead — most sharply, **a running engine does not prove recognition works**.
///
/// Pure value logic: no engine, no session, no clock, no I/O. None of the interesting states can
/// be produced in a test process, which is exactly why the decision is extracted from the service
/// that applies it.
enum ListenerHealthPolicy {

    /// - Parameter state: everything observable at the moment a start is considered.
    /// - Returns: what the start should do.
    static func decide(_ state: ListenerHealthState) -> ListenerHealthDecision {
        // 1. Push-to-talk outranks everything. The always-on listener never runs in silent mode,
        //    and this is the single chokepoint every auto-start path passes through.
        if state.silentMode { return .refuse(.silentMode) }

        // 2. Nobody wants listening. An explicit stop withdraws intent, and a route change or an
        //    ended interruption does not put it back — only a caller asking again does.
        if !state.intent { return .refuse(.noIntent) }

        // 3. Authorization. `unknown` is the pre-flight pass, before anything has been asked.
        if state.permission == .denied { return .refuse(.noPermission) }

        // 4. A pause somebody took on purpose. Only the shared-engine handoff blocks, and only an
        //    automatic start: the consumer holding the capture releases it by asking explicitly.
        //    A silence pause never blocks — see `ListenerPauseReason.silence`.
        if state.origin == .automatic, state.deliberatelyPaused == .sharedEngine {
            return .pausedDeliberately(.sharedEngine)
        }

        // 5. A listener that is genuinely up: flag, engine, tap and a running recognizer all
        //    agreeing. Anything less is not "healthy" — it is the state the old guard mistook for
        //    one. A deliberate pause is not tested here on purpose: a pause that matters has
        //    already taken the recognizer down, so it shows up in the graph rather than needing to
        //    be believed, and the one that does not (silence) leaves a working listener working.
        if state.flagSaysListening,
           state.graph.engineRunning,
           state.graph.tapInstalled,
           state.graph.recognition == .running {
            return .healthy
        }

        // 6. Broken shapes, most specific first.
        //
        //    A finished recognizer beside a running engine is the rule that motivates the whole
        //    decision, so it is asked before anything the flag has an opinion about.
        if case .ended = state.graph.recognition, state.graph.engineRunning {
            return .rebuild(.recognitionEnded)
        }
        //    A task that outlived its engine: obsolete callbacks, a request fed by nothing.
        if state.graph.recognition != .none, !state.graph.engineRunning {
            return .rebuild(.staleRecognitionTask)
        }
        //    The flag claims a listener the graph does not have.
        if state.flagSaysListening, !state.graph.engineRunning {
            return .rebuild(.engineStopped)
        }
        if state.flagSaysListening, state.graph.recognition == .none {
            return .rebuild(.noRecognitionTask)
        }
        //    An engine running with no tap feeds neither the recognizer nor the shared consumers.
        if state.graph.engineRunning, !state.graph.tapInstalled {
            return .rebuild(.tapMissing)
        }

        // 7. Nothing up, nothing broken. This is also how a shared-engine pause comes back: the
        //    engine is running with its tap and its consumers, no recognizer exists, and starting
        //    one reuses the engine instead of tearing it out from under them.
        return .startFresh
    }
}

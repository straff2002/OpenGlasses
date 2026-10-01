import Foundation

/// Plan GU §3 — the end-of-conversation hand-back, in the order that works.
///
/// 1. Finish the app's own audio — the disconnect tone, then "Resuming <media>". This used to run
///    *after* the session was handed back, so the announcement re-paused the very app it named.
/// 2. Stop the recognizer and the engine. Deactivating a session with running I/O fails.
/// 3. Hand the session back: a real deactivation with `.notifyOthersOnDeactivation` when
///    `HandBackDecision` allows it — the only call that tells Podcasts or Music to resume.
/// 4. Re-arm the idle listener (`WakeRearmPolicy` `.restart`: reactivate in the idle plan — phone
///    mic, mixable, A2DP), or stay released (`.skip`: no engine, no lease, nothing hot).
///
/// Stages are injected `@MainActor` closures over the live `AppState`, the same seam pattern as
/// `ConversationStartSequence`, so the order is locked by recorder tests.
enum TurnAudioRelease {

    /// How long the disconnect tone (≈0.24 s) is given to finish when nothing is announced after
    /// it, so the deactivation does not cut it off.
    static let toneSettleSeconds: TimeInterval = 0.3

    struct Deps {
        let playDisconnectTone: @MainActor () -> Void
        /// Speak "Resuming <media>" when something was paused. Returns whether it spoke (and so
        /// already outlasted the tone).
        let announceResumingMedia: @MainActor () async -> Bool
        /// Let the tone finish.
        let settle: @MainActor () async -> Void
        /// Stop the wake recognizer and the shared engine (consumers permitting).
        let stopRecognizerAndEngine: @MainActor () -> Void
        /// Deactivate with notify, or whatever `HandBackDecision` allows instead.
        let handBack: @MainActor () async -> Void
        /// Reactivate in the idle plan and start the listener.
        let rearm: @MainActor () async -> Void
        /// The re-arm was skipped: make sure nothing is left running or held.
        let stayReleased: @MainActor () -> Void
    }

    @MainActor
    static func run(_ deps: Deps, rearm: Bool) async {
        deps.playDisconnectTone()
        let spoke = await deps.announceResumingMedia()
        if !spoke { await deps.settle() }
        deps.stopRecognizerAndEngine()
        await deps.handBack()
        if rearm {
            await deps.rearm()
        } else {
            deps.stayReleased()
        }
    }
}

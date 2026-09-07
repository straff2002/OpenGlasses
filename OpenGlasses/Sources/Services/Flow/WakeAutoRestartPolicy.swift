import Foundation

/// Whether an *automatic* wake-word restart may open the microphone.
///
/// Issue 427 follow-up. The master listening toggle was enforced by some callers and not others:
/// `AppState.returnToWakeWord()` checked it, but the foreground restart did not, and neither did
/// `WakeWordService`'s own route-change / interruption-ended restarts. So with the toggle off the
/// app still brought the listener up and still heard a wake word — field trace (build 371):
/// `becameActive; routeChanged reconfigure; engineReused; listenerStarted` at 16:11:46-47, then
/// `wakeWord detected` at 16:11:49, with `listenerSkippedDisabled` proving the toggle was off.
///
/// A wake word must not be heard while the master toggle is off. This is the one place that rule
/// lives, so a new auto-start path either uses it or is visibly not using it.
enum WakeAutoRestartPolicy {

    /// - Parameters:
    ///   - listeningEnabled: the user's master toggle. Off ⇒ never.
    ///   - silentMode: push-to-talk. Suppresses the always-on listener.
    ///   - isConnected: glasses link. Off ⇒ don't grab the phone mic behind the user's back.
    ///   - micMuted: explicit mute.
    ///   - alreadyListening: nothing to restart.
    static func shouldRestart(listeningEnabled: Bool,
                              silentMode: Bool,
                              isConnected: Bool,
                              micMuted: Bool,
                              alreadyListening: Bool) -> Bool {
        guard listeningEnabled else { return false }
        guard !silentMode else { return false }
        guard isConnected else { return false }
        guard !micMuted else { return false }
        return !alreadyListening
    }
}

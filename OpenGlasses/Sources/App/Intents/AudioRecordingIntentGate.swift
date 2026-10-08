import Foundation

/// The rule iOS holds an `AudioRecordingIntent` to, as two pure decisions.
///
/// Apple: "you must start a Live Activity when you begin the audio recording and keep it active
/// as long as you record audio." iOS 27 enforces it after `perform()` returns, as a fatal error
/// — "AudioRecordingIntent was performed with an active audio session but without a Live
/// Activity" — and the app is aborted, not told (TestFlight build 463, twice in two minutes
/// behind the Action button). The two checks here bracket `AppState.startAskWithoutWakeWord`:
/// one before anything touches audio, one before the intent returns.
enum AudioRecordingIntentGate {
    enum Verdict: Equatable {
        case proceed
        case refuse(Reason)
    }

    enum Reason: Equatable {
        /// The wearer has Live Activities switched off for this app in iOS Settings: no activity
        /// can ever come up, so the microphone must not be opened from the intent at all.
        case liveActivitiesDisabled
        /// The start finished without an activity on the Lock Screen (the request failed, or it
        /// was dismissed): returning now would be the abort, so the ask is ended instead.
        case liveActivityMissing
    }

    /// Before the microphone is touched.
    static func beforeStart(activitiesEnabled: Bool) -> Verdict {
        activitiesEnabled ? .proceed : .refuse(.liveActivitiesDisabled)
    }

    /// Before `perform()` returns.
    static func beforeReturn(activityRunning: Bool) -> Verdict {
        activityRunning ? .proceed : .refuse(.liveActivityMissing)
    }
}

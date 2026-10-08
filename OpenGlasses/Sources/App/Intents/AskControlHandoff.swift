import Foundation
import UIKit

@MainActor
extension AppState {
    /// Start a voice ask now, skipping the wake word: the body of the "Ask Avenkin" App Shortcut
    /// (`AskOpenGlassesIntent`), which always asks in Direct mode. The "Ask Avenkin" control does
    /// not come through here: it is Tap & Talk (`takePendingAskRequest`).
    ///
    /// `AskOpenGlassesIntent` is an `AudioRecordingIntent`, and iOS holds those to a rule it
    /// enforces as a fatal error (iOS 27, `AppIntents/PerformActionExecutorTask.swift:889`;
    /// TestFlight build 463, twice in two minutes behind the Action button): when `perform()`
    /// returns with the audio session active, a Live Activity must be running, or the system
    /// aborts the app. Always-on listening starts one; a wearer who listens by button alone had
    /// none. So this runs the whole start in line — not a detached task that `perform()` races
    /// — brings the activity up before the microphone, and never returns with the microphone
    /// open and no activity to show for it. `returnToWakeWord()` ends the activity again when
    /// nothing else keeps one.
    func startAskWithoutWakeWord() async throws {
        if case .refuse = AudioRecordingIntentGate.beforeStart(
            activitiesEnabled: LiveActivityManager.activitiesEnabled) {
            AppState.persistDebugEvent("[intent] AskOpenGlasses: Live Activities off — refused")
            throw AskOpenGlassesIntent.IntentError.liveActivitiesOff
        }
        liveActivityManager.start(glassesName: glassesService.deviceName ?? "Avenkin")

        // Switch to direct mode if not already
        if currentMode != .direct {
            switchMode(to: .direct)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Skip wake word — go straight to transcription, awaited to the end so the intent's
        // own verification sees the finished state, not a start still in flight.
        wakeWordService.stopListening()
        addDebugEvent("ActionButton: direct transcription requested (bg=\(UIApplication.shared.applicationState == .background))")
        await wakeWordService.configureAudioSession()
        await handleWakeWordDetected(manual: true)
        addDebugEvent("ActionButton: listening started (isListening=\(isListening))")

        if case .refuse = AudioRecordingIntentGate.beforeReturn(activityRunning: liveActivityManager.isRunning) {
            AppState.persistDebugEvent("[intent] AskOpenGlasses: no Live Activity — ending the ask")
            endListeningSession()
            throw AskOpenGlassesIntent.IntentError.liveActivitiesOff
        }
    }

    /// Acts on a press of the "Ask Avenkin" control, if one is pending and fresh. Called on the
    /// control's Darwin notification, on launch and on becoming active; the request is taken once,
    /// so whichever runs first starts the ask and the others find nothing.
    ///
    /// The press is a tap on the talk capsule: `connectAndListen()`, the entry Tap & Talk shares
    /// with the widget, the watch and the Dynamic Island (`TalkEntryPolicy`). So it talks in the
    /// mode the wearer is in, on the phone when the glasses are away, and resumes glasses they
    /// stood down — whatever the capsule would have done had they tapped it.
    func takePendingAskRequest(trigger: String) {
        guard PendingAskRequest.shared.consume() else { return }
        AppState.persistDebugEvent("[control] Ask Avenkin request taken (\(trigger))")
        Task { @MainActor in
            await self.connectAndListen()
        }
    }
}

/// Listens for the Darwin notification the "Ask Avenkin" control posts when it records a press.
/// Darwin notifications cross process boundaries, so a live app hears a press made while it runs.
final class PendingAskObserver {
    static let shared = PendingAskObserver()
    private var started = false
    private var onRequest: (() -> Void)?

    func start(onRequest: @escaping () -> Void) {
        self.onRequest = onRequest
        guard !started else { return }
        started = true

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<PendingAskObserver>.fromOpaque(observer).takeUnretainedValue().onRequest?()
            },
            PendingAskRequest.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}

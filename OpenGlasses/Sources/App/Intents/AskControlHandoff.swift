import Foundation

@MainActor
extension AppState {
    /// Start a voice ask now, skipping the wake word: the body of the "Ask Avenkin" App Shortcut
    /// (`AskOpenGlassesIntent`), which always asks in Direct mode. The "Ask Avenkin" control does
    /// not come through here: it is Tap & Talk (`takePendingAskRequest`).
    func startAskWithoutWakeWord() async throws {
        // Switch to direct mode if not already
        if currentMode != .direct {
            switchMode(to: .direct)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Skip wake word — go straight to transcription
        wakeWordService.stopListening()
        startDirectTranscription()
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

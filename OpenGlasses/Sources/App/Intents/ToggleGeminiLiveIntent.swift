import AppIntents

/// AppIntent for the iPhone Action Button — toggles a Gemini Live session.
/// User configures: Settings → Action Button → Shortcut → "Toggle Gemini Live".
struct ToggleGeminiLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Gemini Live"
    static var description = IntentDescription("Start or stop a Gemini Live session")

    static var isDiscoverable: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("gemini_live_toggle")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Plan FF P1/PR3: the mode switch, the wait and the start are the activator's, not this
        // intent's. What used to be here — switch, sleep 600 ms, start — raced every other entry
        // point and could not be cancelled by a Stop that arrived in the middle of it.
        if appState.geminiLiveSession.isActive {
            appState.stopLiveSession(.geminiLive, source: .actionButton)
        } else {
            await appState.requestLiveSession(.geminiLive, source: .actionButton)
        }

        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}

import AppIntents

/// Intent to disable listening — triggered from Live Activity button, Siri, or widget.
/// Also accessible from app context via AppStateProvider.
struct DisableListeningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Disable Listening"
    static var description = IntentDescription("Stop wake word detection and end Live Activity")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Write to UserDefaults (works from both app and widget)
        UserDefaults.standard.set(false, forKey: "listeningEnabled")
        // If app is running, update observable state immediately
        if let appState = AppStateProvider.shared {
            appState.setListeningEnabled(false)
        }
        return .result()
    }
}

/// Intent to enable listening — triggered from Siri or widget.
struct EnableListeningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Enable Listening"
    static var description = IntentDescription("Start wake word detection and Live Activity")

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "listeningEnabled")
        if let appState = AppStateProvider.shared {
            appState.setListeningEnabled(true)
        }
        return .result()
    }
}

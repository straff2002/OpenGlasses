import AppIntents

/// Intent to disable listening — triggered from Live Activity button, Siri, or widget.
/// Also accessible from app context via AppStateProvider.
struct DisableListeningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Disable Listening"
    static var description = IntentDescription("Stop wake word detection and end Live Activity")

    @MainActor
    func perform() async throws -> some IntentResult {
        ListeningIntentWrite.apply(false)
        return .result()
    }
}

/// Intent to enable listening — triggered from Siri or widget.
struct EnableListeningIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Enable Listening"
    static var description = IntentDescription("Start wake word detection and Live Activity")

    @MainActor
    func perform() async throws -> some IntentResult {
        ListeningIntentWrite.apply(true)
        return .result()
    }
}

/// What both listening intents do with the new value.
enum ListeningIntentWrite {
    /// Both stores: the App Group copy is the one the widget, the control and a later launch read
    /// (`Config.listeningEnabled` prefers it). Writing only the app's own defaults let a press that
    /// launched the app in the background — before any `AppState` — leave the shared flag where it
    /// was, so the widget kept saying "Stop" and the next launch switched listening back on.
    @MainActor
    static func apply(_ enabled: Bool) {
        Config.setListeningEnabled(enabled)
        if let appState = AppStateProvider.shared {
            // Updates observable state immediately and redraws the widget on a change.
            appState.setListeningEnabled(enabled)
        } else {
            WidgetCenterReloader().reloadListeningSurfaces()
        }
    }
}

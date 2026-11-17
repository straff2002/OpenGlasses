import AppIntents

/// The Home Screen widget's "Listen" button: turn wake-word listening on, from the app.
///
/// Compiled into **both** the app and the widget extension (`project.base.yml`,
/// `project.phone-only.yml`), the same arrangement as `AskAvenkinControlIntent`. A widget button
/// runs its intent in the extension by default, and the extension can only flip the shared flag:
/// iOS refuses a microphone start from the background, so with the app suspended the button used to
/// read "Stop" while nothing listened. Foreground, immediately: the press brings the app up, the
/// app's copy of this intent runs there, and listening starts from the foreground.
///
/// `perform()` touches only the App Group (`AppState` may not exist yet on a cold launch). The
/// write posts the listening-changed Darwin notification, which a live app answers with
/// `setListeningEnabled(true)`; a cold launch reads the same flag when it becomes active.
///
/// Stopping needs none of this — a listening app is already running — so the widget's Stop button
/// stays in the extension (`DisableListeningIntent`).
struct StartListeningFromWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Listening"
    static var description = IntentDescription("Open Avenkin and turn on wake-word listening.")

    /// The widget's button only; Shortcuts and Siri have `EnableListeningIntent`.
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        SharedAppState.isListening = true
        return .result()
    }
}

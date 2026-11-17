import AppIntents
import WidgetKit

/// Widget-side intent to disable listening — the Home Screen widget's Stop button. Writes to the
/// shared App Group defaults so the running app picks it up via Darwin notification, and reloads
/// widget timelines. Runs in the extension: a listening app is alive to hear it. Starting goes
/// through the app instead (`StartListeningFromWidgetIntent`).
struct DisableListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Disable Listening"
    static var description = IntentDescription("Stop wake word detection.")

    func perform() async throws -> some IntentResult {
        SharedAppState.isListening = false
        return .result()
    }
}

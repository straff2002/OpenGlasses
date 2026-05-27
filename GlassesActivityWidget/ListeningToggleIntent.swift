import AppIntents
import WidgetKit

/// Widget-side intent to disable listening. Writes to the shared App Group defaults so
/// the running app picks it up via Darwin notification, and reloads widget timelines.
struct DisableListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Disable Listening"
    static var description = IntentDescription("Stop wake word detection.")

    func perform() async throws -> some IntentResult {
        SharedAppState.isListening = false
        return .result()
    }
}

/// Widget-side toggle — flips the current listening state in shared defaults.
struct ToggleListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Listening"
    static var description = IntentDescription("Toggle wake-word listening on or off.")

    func perform() async throws -> some IntentResult {
        SharedAppState.isListening.toggle()
        return .result()
    }
}

/// SetValueIntent variant for Control Widget toggles (iOS 18+ Action Button / Control Center).
@available(iOS 18.0, *)
struct SetListeningIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Listening State"

    @Parameter(title: "Listening")
    var value: Bool

    func perform() async throws -> some IntentResult {
        SharedAppState.isListening = value
        return .result()
    }
}

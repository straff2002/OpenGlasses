import AppIntents

/// The "Ask Avenkin" control's action: open Avenkin and start listening straight away, with no
/// wake word — the hands-free launcher for the Action button and Control Center.
///
/// Compiled into **both** the app and the widget extension (`project.base.yml`). A control whose
/// intent opens the app must have that intent in the app target too: the system then launches the
/// app and runs `perform()` in the app's process. The extension's copy is what the control is built
/// from; the app's copy is what runs.
///
/// `perform()` does not touch `AppState` (the extension cannot compile it, and on a cold launch it
/// does not exist yet). It records a `PendingAskRequest`, which the app takes on its Darwin
/// notification, on launch or on becoming active, and answers as a tap on the Tap & Talk capsule
/// would (`AppState.connectAndListen()`).
struct AskAvenkinControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Avenkin"
    static var description = IntentDescription("Open Avenkin and start listening right away, without the wake word.")

    /// The App Shortcut "Ask Avenkin" is the one Shortcuts lists; this one exists for the control.
    static var isDiscoverable: Bool { false }
    /// Foreground, immediately: the press brings the app up, so the microphone starts from the
    /// foreground (iOS refuses a background start) and the wearer sees it listening.
    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        PendingAskRequest.submit()
        return .result()
    }
}

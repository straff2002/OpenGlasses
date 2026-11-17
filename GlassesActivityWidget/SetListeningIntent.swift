import AppIntents

/// The Action button and Control Center listening toggle (`ListeningControlWidget`).
///
/// Compiled into **both** the app and the widget extension (`project.base.yml`,
/// `project.phone-only.yml`), like `StartListeningFromWidgetIntent`. Turning listening off works
/// from the background: it only writes the shared flag, and a listening app is alive to hear it.
/// Turning it on cannot — iOS refuses a microphone start from the background, so with the app
/// suspended the control read "On" while nothing listened. Background, with a dynamic foreground:
/// an "on" press brings the app up first (`continueInForeground`), then writes the flag, which a
/// live app answers with `setListeningEnabled(true)` and a cold launch reads when it becomes active.
@available(iOS 18.0, *)
struct SetListeningIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Set Listening State"

    /// The control only; Shortcuts and Siri have `EnableListeningIntent` / `DisableListeningIntent`.
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Listening")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            // The press is the wearer's confirmation; no extra prompt.
            try await continueInForeground(nil, alwaysConfirm: false)
        }
        SharedAppState.isListening = value
        return .result()
    }
}

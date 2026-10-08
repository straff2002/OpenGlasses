import AppIntents

/// AppIntent for the iPhone Action Button — starts listening for a voice command.
/// User configures: Settings → Action Button → Shortcut → "Ask OpenGlasses".
/// Skips wake word detection entirely — just starts transcribing immediately.
// AudioRecordingIntent (iOS 18+): grants BACKGROUND microphone-start rights for intent
// invocations. Without it, an Action-button press with the app backgrounded is refused by
// iOS at session activation (CoreAudio '!pla' then CannotInterruptOthers — device-traced:
// "listening" showed but zero audio was captured, and the Live Activity was denied with
// "Target is not foreground").
struct AskOpenGlassesIntent: AppIntent, AudioRecordingIntent {
    static var title: LocalizedStringResource = "Ask Avenkin"
    static var description = IntentDescription("Start listening for a voice command without the wake word")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Static writer: logs even when AppState is unavailable — distinguishes "iOS never
        // invoked the intent" from "perform() bailed at the guard".
        AppState.persistDebugEvent("[intent] AskOpenGlasses perform entered")
        guard let appState = AppStateProvider.shared else {
            AppState.persistDebugEvent("[intent] AskOpenGlasses: AppState unavailable — appNotRunning")
            throw IntentError.appNotRunning
        }

        try await appState.startAskWithoutWakeWord()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        /// iOS lets an `AudioRecordingIntent` record only alongside a Live Activity, and the
        /// wearer has those switched off for this app (see `AppState.startAskWithoutWakeWord`).
        case liveActivitiesOff

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .appNotRunning:
                return "Avenkin is not running. Open the app first."
            case .liveActivitiesOff:
                return "Avenkin can't listen from a button until Live Activities are allowed for it in iOS Settings."
            }
        }
    }
}

/// AppIntent to take a photo and analyze it.
struct TakePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Avenkin Photo"
    static var description = IntentDescription("Take a photo and describe what you see")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("take_photo")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        await appState.captureAndAnalyzePhoto()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "Avenkin is not running. Open the app first."
        }
    }
}

/// Register shortcuts so they appear in the Shortcuts app and Action Button picker.
struct OpenGlassesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // App Shortcut phrases may only interpolate parameters whose type is an
        // AppEntity or AppEnum — Siri needs a finite, resolvable set to predict
        // against. A free-form String (the question) is rejected by the AppIntents
        // metadata processor with a *halting* error that wipes ALL exported intent
        // metadata, so it's resolved two-step via `requestValueDialog`. The persona,
        // however, IS an AppEntity, so it can ride inside the phrase ("Ask Claude on
        // OpenGlasses…"). Persona is optional — the generic phrase falls back to the
        // active/first persona, so this one intent covers both the generic and the
        // persona-targeted ask (and keeps us at iOS's 10-shortcut cap).
        AppShortcut(
            intent: AskPersonaIntent(),
            phrases: [
                "Ask \(.applicationName) a question",
                "Ask \(\.$persona) on \(.applicationName)",
                "Ask \(\.$persona) \(.applicationName)"
            ],
            shortTitle: "Ask a Question",
            systemImageName: "bubble.left.and.bubble.right.fill"
        )
        AppShortcut(
            intent: AskOpenGlassesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) listen"
            ],
            shortTitle: "Ask Avenkin",
            // The Avenkin mark as a custom SF Symbol template (Assets: AvenkinSymbol.symbolset —
            // Ultralight/Regular/Black small sources plus Regular medium, so every weight and
            // scale interpolates). The
            // metadata processor embeds referenced custom symbols so system surfaces (Action
            // button pane, Shortcuts) can render them. A "?" on those surfaces is iOS's stale
            // shortcut-metadata cache (dev-reinstall churn) — restart the phone, don't blame
            // the symbol: the "?" appeared even for plain "mic.fill".
            systemImageName: "AvenkinSymbol"
        )
        AppShortcut(
            intent: TakePhotoIntent(),
            phrases: [
                "\(.applicationName) take a photo",
                "Photo with \(.applicationName)"
            ],
            shortTitle: "Take Photo",
            systemImageName: "camera.fill"
        )
        AppShortcut(
            intent: ToggleGeminiLiveIntent(),
            phrases: [
                "Toggle \(.applicationName) live",
                "\(.applicationName) live mode"
            ],
            shortTitle: "Gemini Live",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: ReadTextIntent(),
            phrases: [
                "Read this with \(.applicationName)",
                "\(.applicationName) read this"
            ],
            shortTitle: "Read Text",
            systemImageName: "text.viewfinder"
        )
        // Plan BQ: the parameterized action shortcut — one phrase covers every action the
        // user has exposed (built-in toggles, harvested capabilities, hand-made actions),
        // because the AppEntity's query is runtime data. Took AnalyzeFood's slot under the
        // 10-shortcut cap (the intent survives; food analysis stays reachable via this
        // shortcut's catalog and the glasses loop). Call
        // `OpenGlassesShortcuts.updateAppShortcutParameters()` after any catalog mutation.
        AppShortcut(
            intent: RunGlassesActionIntent(),
            phrases: [
                "Run \(\.$action) on \(.applicationName)",
                "\(\.$action) with \(.applicationName)"
            ],
            shortTitle: "Run Action",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: DescribeEnvironmentIntent(),
            phrases: [
                "Describe surroundings \(.applicationName)",
                "\(.applicationName) what's around me"
            ],
            shortTitle: "Describe Environment",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: ConnectGlassesIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "\(.applicationName) connect"
            ],
            shortTitle: "Connect Glasses",
            systemImageName: "eyeglasses"
        )
        AppShortcut(
            intent: DisableListeningIntent(),
            phrases: [
                "Turn off \(.applicationName)",
                "Stop \(.applicationName) listening",
                "\(.applicationName) stop listening"
            ],
            shortTitle: "Stop Listening",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: EnableListeningIntent(),
            phrases: [
                "Turn on \(.applicationName)",
                "Start \(.applicationName) listening",
                "\(.applicationName) start listening"
            ],
            shortTitle: "Start Listening",
            systemImageName: "mic.fill"
        )
    }
}

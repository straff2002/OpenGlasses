import AppIntents

/// AppIntent for the iPhone Action Button — starts listening for a voice command.
/// User configures: Settings → Action Button → Shortcut → "Ask OpenGlasses".
/// Skips wake word detection entirely — just starts transcribing immediately.
struct AskOpenGlassesIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask OpenGlasses"
    static var description = IntentDescription("Start listening for a voice command without the wake word")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Switch to direct mode if not already
        if appState.currentMode != .direct {
            appState.switchMode(to: .direct)
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Skip wake word — go straight to transcription
        appState.wakeWordService.stopListening()
        appState.startDirectTranscription()

        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}

/// AppIntent to take a photo and analyze it.
struct TakePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "OpenGlasses Photo"
    static var description = IntentDescription("Take a photo with the glasses and describe what you see")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        await appState.captureAndAnalyzePhoto()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "OpenGlasses is not running. Open the app first."
        }
    }
}

/// Register shortcuts so they appear in the Shortcuts app and Action Button picker.
struct OpenGlassesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOpenGlassesIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Hey \(.applicationName)",
                "\(.applicationName) listen"
            ],
            shortTitle: "Ask OpenGlasses",
            systemImageName: "mic.fill"
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
        AppShortcut(
            intent: AnalyzeFoodIntent(),
            phrases: [
                "Is this healthy \(.applicationName)",
                "\(.applicationName) analyze food"
            ],
            shortTitle: "Analyze Food",
            systemImageName: "fork.knife"
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
            intent: StartMuseumModeIntent(),
            phrases: [
                "\(.applicationName) museum mode",
                "Start museum guide with \(.applicationName)"
            ],
            shortTitle: "Museum Guide",
            systemImageName: "building.columns"
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

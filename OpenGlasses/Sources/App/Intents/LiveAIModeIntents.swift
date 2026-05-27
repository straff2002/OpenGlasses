import AppIntents

/// LiveAI mode enum for Siri — maps to the built-in LiveAIMode presets.
enum LiveAIModeParam: String, AppEnum {
    case standard = "standard"
    case museum = "museum"
    case accessibility = "accessibility"
    case reading = "reading"
    case translator = "translator"
    case tutor = "tutor"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "LiveAI Mode")

    static var caseDisplayRepresentations: [LiveAIModeParam: DisplayRepresentation] {
        [
            .standard: "Standard",
            .museum: "Museum Guide",
            .accessibility: "Blind Assistant",
            .reading: "Reading Assistant",
            .translator: "Live Translator",
            .tutor: "Language Tutor",
        ]
    }
}

/// Siri Intent: Start Gemini Live in a specific mode.
/// "Hey Siri, start museum mode in OpenGlasses"
struct StartLiveAIModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Start LiveAI Mode"
    static var description = IntentDescription("Start a Gemini Live session in a specific mode")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Mode", default: .standard)
    var mode: LiveAIModeParam

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Set the LiveAI mode
        Config.setActiveLiveAIModeId(mode.rawValue)

        // Switch to Gemini Live if not already
        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }

        // Start session if not active (or restart to pick up new mode)
        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await appState.geminiLiveSession.startSession()

        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "OpenGlasses is not running. Open the app first." }
    }
}

/// Shortcut: Start museum guide mode (common use case for glasses at museums)
struct StartMuseumModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Museum Guide Mode"
    static var description = IntentDescription("Start Gemini Live as a museum docent and art expert")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("museum")
        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await appState.geminiLiveSession.startSession()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "OpenGlasses is not running." }
    }
}

/// Shortcut: Start blind assistant mode
struct StartAccessibilityModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Blind Assistant Mode"
    static var description = IntentDescription("Start Gemini Live as a visual accessibility assistant")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("accessibility")
        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await appState.geminiLiveSession.startSession()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "OpenGlasses is not running." }
    }
}

/// Shortcut: Start live translator mode
struct StartTranslatorModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Live Translator Mode"
    static var description = IntentDescription("Start Gemini Live as a real-time translator")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("translator")
        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await appState.geminiLiveSession.startSession()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "OpenGlasses is not running." }
    }
}

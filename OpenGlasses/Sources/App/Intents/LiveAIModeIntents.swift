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
        try IntentSupport.requireEnabled("live_mode_\(mode.rawValue)")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Set the LiveAI mode
        Config.setActiveLiveAIModeId(mode.rawValue)

        // Plan FF P1/PR3: one activation owner. `restartIfActive` is what the stop-then-start
        // below used to spell out — a running session has to come back under the newly selected
        // preset, and the settle between the two is `ModeSwitchPolicy.settleDelay` rather than a
        // second guess at the same handover.
        await appState.requestLiveSession(.geminiLive, source: .siriShortcut, restartIfActive: true)

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
        try IntentSupport.requireEnabled("live_mode_museum")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("museum")
        await appState.requestLiveSession(.geminiLive, source: .siriShortcut, restartIfActive: true)
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
        try IntentSupport.requireEnabled("live_mode_accessibility")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("accessibility")
        await appState.requestLiveSession(.geminiLive, source: .siriShortcut, restartIfActive: true)
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
        try IntentSupport.requireEnabled("live_mode_translator")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        Config.setActiveLiveAIModeId("translator")
        await appState.requestLiveSession(.geminiLive, source: .siriShortcut, restartIfActive: true)
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "OpenGlasses is not running." }
    }
}

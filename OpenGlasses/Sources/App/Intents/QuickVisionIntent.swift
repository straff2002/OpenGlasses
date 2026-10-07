import AppIntents

/// QuickVision modes — each triggers a camera capture with a specialized prompt.
enum QuickVisionMode: String, AppEnum {
    case describe = "describe"
    case read = "read"
    case translate = "translate"
    case health = "health"
    case identify = "identify"
    case accessibility = "accessibility"

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Vision Mode")

    static var caseDisplayRepresentations: [QuickVisionMode: DisplayRepresentation] {
        [
            .describe: "Describe Scene",
            .read: "Read Text",
            .translate: "Translate Text",
            .health: "Analyze Food",
            .identify: "Identify Object",
            .accessibility: "Describe Environment",
        ]
    }

    /// The Plan BQ built-in action id this mode maps to, for the Settings → Siri & Search
    /// runtime guard (`IntentSupport.requireEnabled`).
    var builtinActionId: String {
        switch self {
        case .describe: return "describe_scene"
        case .read: return "read_text"
        case .translate: return "translate_text"
        case .health: return "analyze_food"
        case .identify: return "identify_object"
        case .accessibility: return "describe_environment"
        }
    }

    var prompt: String {
        switch self {
        case .describe:
            return "Describe the scene and the main objects or readable text in front of the wearer, in two or three spoken sentences. If the picture is too close, too dark or blurry, say that first."
        case .read:
            return "Read all visible text in this image. Transcribe it exactly as written, then provide a brief summary of the content."
        case .translate:
            return "Read any text visible in this image. Transcribe the original text, identify the language, then translate it to the user's language."
        case .health:
            return """
            Analyze the food in this image. For each food item visible, estimate:
            - Calories (kcal)
            - Protein (g)
            - Fat (g)
            - Carbs (g)
            Give a brief health assessment and any dietary suggestions. Keep it conversational for TTS.
            """
        case .identify:
            return "Identify the main object, product, landmark, or item in this image. Provide its name, brief description, and any notable facts. If it's a product, include brand and model if visible."
        case .accessibility:
            return "Describe the environment and surroundings for a visually impaired user. Focus on: obstacles, people, signage, doors, stairs, vehicles, and spatial layout. Be specific about distances and directions (left, right, ahead)."
        }
    }
}

/// Siri Intent: capture a photo with the glasses and analyze it in a specific mode.
struct QuickVisionIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Vision"
    static var description = IntentDescription("Take a photo and analyze it")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Mode", default: .describe)
    var mode: QuickVisionMode

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled(mode.builtinActionId)
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        await appState.capturePhotoAndSend(prompt: mode.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning

        var localizedStringResource: LocalizedStringResource {
            "Avenkin is not running. Open the app first."
        }
    }
}

/// Shortcut: "Read this" — OCR + read aloud
struct ReadTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Text"
    static var description = IntentDescription("Read text the camera can see")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("read_text")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.read.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running." }
    }
}

/// Shortcut: "Is this healthy?" — food nutrition analysis
struct AnalyzeFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Analyze Food"
    static var description = IntentDescription("Analyze food nutrition from what the camera sees")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("analyze_food")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.health.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running." }
    }
}

/// Shortcut: "Describe environment" — accessibility mode
struct DescribeEnvironmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Describe Environment"
    static var description = IntentDescription("Describe surroundings for accessibility")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("describe_environment")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        await appState.capturePhotoAndSend(prompt: QuickVisionMode.accessibility.prompt)
        return .result(value: appState.lastResponse)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running." }
    }
}

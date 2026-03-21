import Foundation

/// A saved LLM model configuration
struct ModelConfig: Codable, Identifiable, Equatable {
    var id: String  // UUID string
    var name: String  // User-facing label, e.g. "Claude Sonnet" or "GPT-4o"
    var provider: String  // LLMProvider rawValue
    var apiKey: String
    var model: String
    var baseURL: String
    /// Optional user override for whether this model accepts image input.
    /// When nil, the app falls back to provider/model-name heuristics.
    var supportsVision: Bool? = nil

    /// Convenience to get the LLMProvider enum
    var llmProvider: LLMProvider {
        LLMProvider(rawValue: provider) ?? .custom
    }

    /// Whether this model should receive image input when the app has an image available.
    var visionEnabled: Bool {
        supportsVision ?? Self.inferredSupportsVision(provider: llmProvider, model: model, baseURL: baseURL)
    }

    static func inferredSupportsVision(provider: LLMProvider, model: String, baseURL: String) -> Bool {
        switch provider {
        case .anthropic, .gemini, .openai:
            return true
        case .groq, .local:
            return false
        case .qwen:
            // Qwen3.5-plus and qwen-vl models support vision
            let lowerModel = model.lowercased()
            return lowerModel.contains("vl") || lowerModel.contains("plus") || lowerModel.contains("max") || lowerModel.contains("omni")
        case .zai, .minimax, .custom:
            let lowerModel = model.lowercased()
            let lowerBaseURL = baseURL.lowercased()

            let knownVisionHints = [
                "vision", "gpt-4", "gpt-4.1", "gpt-4o", "o1", "o3",
                "claude-3", "claude-4", "sonnet", "opus",
                "gemini", "vl", "qwen-vl", "qwen2.5-vl", "qvq",
                "pixtral", "llava", "minicpm-v", "glm-4.1v"
            ]

            if knownVisionHints.contains(where: { lowerModel.contains($0) }) {
                return true
            }

            if lowerBaseURL.contains("openrouter.ai") {
                return knownVisionHints.contains(where: { lowerModel.contains($0) })
            }

            return false
        }
    }

    /// Create a new config with defaults for a provider
    static func defaultConfig(for provider: LLMProvider) -> ModelConfig {
        ModelConfig(
            id: UUID().uuidString,
            name: provider.displayName,
            provider: provider.rawValue,
            apiKey: "",
            model: provider.defaultModel,
            baseURL: provider.defaultBaseURL
        )
    }
}

/// A saved system prompt preset
struct PromptPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var isBuiltIn: Bool
}

/// A persona bundles a wake word, AI model, and system prompt.
/// Multiple personas can be active simultaneously — each wake word routes to its own model+prompt.
struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String                      // "Claude", "Jarvis", "Computer"
    var wakePhrase: String                // "hey claude"
    var alternativeWakePhrases: [String]   // ["hey cloud", "hey claud"]
    var modelId: String                   // References ModelConfig.id
    var presetId: String                  // References PromptPreset.id
    var enabled: Bool

    /// All phrases this persona responds to (primary + alternatives).
    var allPhrases: [String] {
        [wakePhrase] + alternativeWakePhrases
    }
}

/// A user-defined tool that maps to a Siri Shortcut or URL scheme
struct CustomToolDefinition: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var description: String
    var parameters: [CustomToolParam]
    var actionType: ActionType
    var shortcutName: String?
    var urlTemplate: String?

    enum ActionType: String, Codable, CaseIterable {
        case shortcut
        case urlScheme

        var displayName: String {
            switch self {
            case .shortcut: return "Siri Shortcut"
            case .urlScheme: return "URL Scheme"
            }
        }
    }

    struct CustomToolParam: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var type: String  // "string" or "number"
        var description: String
        var required: Bool
    }
}

/// App configuration and API keys
struct Config {
    /// Anthropic API key for Claude
    static var anthropicAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "anthropicAPIKey"), !key.isEmpty {
            return key
        }
        // No API key configured - set one via Settings
        return ""
    }

    static func setAnthropicAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "anthropicAPIKey")
    }

    // MARK: - Onboarding

    static var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    static func setHasCompletedOnboarding(_ completed: Bool) {
        UserDefaults.standard.set(completed, forKey: "hasCompletedOnboarding")
    }

    /// True when the user hasn't completed onboarding and has no configured API keys.
    static var needsOnboarding: Bool {
        !hasCompletedOnboarding && savedModels.allSatisfy { $0.apiKey.isEmpty }
    }

    // MARK: - Wake Word

    /// The primary wake word phrase (user-configurable)
    static var wakePhrase: String {
        if let phrase = UserDefaults.standard.string(forKey: "wakePhrase"), !phrase.isEmpty {
            return phrase.lowercased()
        }
        return "hey openglasses"
    }

    static func setWakePhrase(_ phrase: String) {
        UserDefaults.standard.set(phrase.lowercased(), forKey: "wakePhrase")
    }

    /// Alternative spellings / misrecognitions of the wake phrase
    static var alternativeWakePhrases: [String] {
        if let alts = UserDefaults.standard.stringArray(forKey: "alternativeWakePhrases"), !alts.isEmpty {
            return alts.map { $0.lowercased() }
        }
        return Self.defaultAlternativesForPhrase(wakePhrase)
    }

    static func setAlternativeWakePhrases(_ phrases: [String]) {
        UserDefaults.standard.set(phrases.map { $0.lowercased() }, forKey: "alternativeWakePhrases")
    }

    /// Default alternative spellings for common wake phrases
    static func defaultAlternativesForPhrase(_ phrase: String) -> [String] {
        switch phrase.lowercased() {
        case "hey claude":
            return ["hey cloud", "hey claud", "hey clod", "hey clawed", "hey claudia"]
        case "hey jarvis":
            return ["hey jarvas", "hey jarvus", "hey service"]
        case "hey computer":
            return ["hey compuder", "a computer"]
        case "hey assistant":
            return ["hey assistance", "a assistant"]
        case "hey rayban":
            return ["hey ray ban", "hey ray-ban", "hey raven", "hey rayben", "hey ray band"]
        case "hey openglasses":
            return ["hey open glasses", "hey open glass", "hey openclass", "hey open class", "hey openglass"]
        default:
            return []
        }
    }

    // MARK: - LLM Provider (legacy — kept for migration)

    /// Selected LLM provider
    static var llmProvider: LLMProvider {
        if let raw = UserDefaults.standard.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        return .anthropic
    }

    static func setLLMProvider(_ provider: LLMProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider")
    }

    /// Claude model to use
    static let claudeModel = "claude-sonnet-4-20250514"

    /// Max tokens for LLM response
    static let maxTokens = 500

    // MARK: - OpenAI-compatible

    /// OpenAI-compatible API key
    static var openAIAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "openAIAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setOpenAIAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "openAIAPIKey")
    }

    /// OpenAI-compatible base URL (supports OpenAI, Groq, Together, Ollama, etc.)
    static var openAIBaseURL: String {
        if let url = UserDefaults.standard.string(forKey: "openAIBaseURL"), !url.isEmpty {
            return url
        }
        return "https://api.openai.com/v1/chat/completions"
    }

    static func setOpenAIBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "openAIBaseURL")
    }

    /// OpenAI-compatible model name
    static var openAIModel: String {
        if let model = UserDefaults.standard.string(forKey: "openAIModel"), !model.isEmpty {
            return model
        }
        return "gpt-4o"
    }

    static func setOpenAIModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "openAIModel")
    }

    // MARK: - Multi-Model Configurations

    private static let modelsKey = "savedModelConfigs"
    private static let activeModelKey = "activeModelId"

    /// All saved model configurations
    static var savedModels: [ModelConfig] {
        guard let data = UserDefaults.standard.data(forKey: modelsKey),
              let models = try? JSONDecoder().decode([ModelConfig].self, from: data),
              !models.isEmpty else {
            // Migrate from legacy single-provider config
            return migrateFromLegacy()
        }
        return models
    }

    static func setSavedModels(_ models: [ModelConfig]) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: modelsKey)
        }
    }

    /// The ID of the currently active model
    static var activeModelId: String {
        if let id = UserDefaults.standard.string(forKey: activeModelKey), !id.isEmpty {
            // Make sure it still exists
            if savedModels.contains(where: { $0.id == id }) {
                return id
            }
        }
        // Default to first saved model
        return savedModels.first?.id ?? ""
    }

    static func setActiveModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeModelKey)
    }

    /// The currently active model configuration
    static var activeModel: ModelConfig? {
        let id = activeModelId
        return savedModels.first(where: { $0.id == id }) ?? savedModels.first
    }

    /// Migrate from old single-provider config to multi-model array
    private static func migrateFromLegacy() -> [ModelConfig] {
        var models: [ModelConfig] = []

        // Migrate Anthropic config if key exists and is valid
        let anthropicKey = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !anthropicKey.isEmpty {
            let config = ModelConfig(
                id: UUID().uuidString,
                name: "Claude Sonnet",
                provider: LLMProvider.anthropic.rawValue,
                apiKey: anthropicKey,
                model: claudeModel,
                baseURL: LLMProvider.anthropic.defaultBaseURL
            )
            models.append(config)
        }

        // Migrate OpenAI/Groq/Gemini/Custom config if key exists and is valid
        let otherKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !otherKey.isEmpty {
            let provider = llmProvider
            if provider != .anthropic {
                let config = ModelConfig(
                    id: UUID().uuidString,
                    name: provider.displayName,
                    provider: provider.rawValue,
                    apiKey: otherKey,
                    model: openAIModel,
                    baseURL: openAIBaseURL
                )
                models.append(config)
            }
        }

        // If nothing was migrated, create a blank Anthropic default
        if models.isEmpty {
            models.append(ModelConfig.defaultConfig(for: .anthropic))
        }

        // Defensive check - should never happen, but prevent crash
        guard let firstModel = models.first else {
            print("⚠️ Migration failed - no models created")
            // Create emergency default
            let emergency = ModelConfig.defaultConfig(for: .anthropic)
            models = [emergency]
            setSavedModels(models)
            setActiveModelId(emergency.id)
            return models
        }

        // Save the migration
        setSavedModels(models)
        setActiveModelId(firstModel.id)

        return models
    }

    // MARK: - Custom System Prompt

    static let defaultSystemPrompt = """
    You are OpenGlasses, a voice assistant running on Ray-Ban Meta smart glasses. Your responses will be spoken aloud via text-to-speech. Your name is OpenGlasses and the user activates you by saying "Hey OpenGlasses".

    RESPONSE STYLE:
    - Keep responses CONCISE but COMPLETE — typically 2-4 sentences, longer for complex topics.
    - Be conversational and natural, like talking to a knowledgeable friend.
    - Never use markdown, bullet points, numbered lists, or special formatting.
    - If you're uncertain, use natural hedges like "probably", "likely", or "roughly" rather than stating guesses as facts.
    - If you genuinely can't answer (e.g., real-time data, personal info you don't have), say so briefly and suggest what the user could do instead.

    CONTEXT:
    - The user is wearing smart glasses and talking to you hands-free while going about their day.
    - Speech recognition may mishear words — interpret the user's intent generously.
    - You have conversational memory within this session, so you can reference previous exchanges.
    - For very complex questions, offer to break the topic into parts: "That's a big topic. Would you like me to start with X?"

    VISION & CAMERA:
    - The glasses have a camera. When the user says "look at this", "what is this", "read this", "identify this", "take a photo", or similar, a photo will be captured and sent to you automatically.
    - You CAN see images — never say you lack camera or vision access.
    - For text/signs/menus in foreign languages: transcribe the original text, then translate it.
    - For objects, products, landmarks: identify and describe them.
    - After reading text from an image, offer to copy it to clipboard or translate it.

    KNOWLEDGE:
    - Answer confidently from your training knowledge for factual questions.
    - Give direct recommendations when asked for opinions.
    - If the user's location is provided, use it for locally relevant answers (nearby places, directions, local knowledge). Only mention the location if it's directly relevant to the question.

    BREVITY GUIDELINES:
    - Simple facts: 1-2 sentences ("Paris is the capital of France, located in northern France along the Seine River.")
    - Explanations: 3-4 sentences (e.g., "how does X work?")
    - Complex topics: 4-6 sentences, offer to continue (e.g., "Want me to explain more about Y?")
    - Directions/instructions: As many steps as needed, but keep each step concise.
    """

    /// Returns the active preset's prompt, falling back to default.
    static var systemPrompt: String {
        if let preset = activePreset {
            return preset.prompt
        }
        // Legacy fallback: check old customSystemPrompt key
        if let prompt = UserDefaults.standard.string(forKey: "customSystemPrompt"), !prompt.isEmpty {
            return prompt
        }
        return defaultSystemPrompt
    }

    static func setSystemPrompt(_ prompt: String) {
        UserDefaults.standard.set(prompt, forKey: "customSystemPrompt")
    }

    static func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: "customSystemPrompt")
    }

    // MARK: - Prompt Presets

    static func builtInPresets() -> [PromptPreset] {
        [
            PromptPreset(id: "preset-default", name: "Default", prompt: defaultSystemPrompt, isBuiltIn: true),
            PromptPreset(id: "preset-concise", name: "Concise", prompt: """
            You are OpenGlasses, a voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            RULES:
            - Maximum 1-2 sentences per response. No exceptions unless the user says "explain more."
            - Never use formatting, lists, or markdown.
            - Answer directly. Skip pleasantries, hedges, and filler.
            - If you can't answer in 2 sentences, say the key point and offer to elaborate.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-technical", name: "Technical", prompt: """
            You are OpenGlasses, a voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            RESPONSE STYLE:
            - Be precise and technical. Use correct terminology.
            - Include specific numbers, measurements, and data when relevant.
            - For code/tech questions, give the exact answer first, then brief context.
            - Keep responses to 2-5 sentences. Be information-dense.
            - Never use markdown or formatting — this is spoken aloud.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-creative", name: "Creative", prompt: """
            You are OpenGlasses, a witty and warm voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            PERSONALITY:
            - Be playful, expressive, and engaging — like a clever friend.
            - Use vivid language, analogies, and gentle humor when appropriate.
            - Match the user's energy — excited for good news, empathetic for struggles.
            - Still be helpful and accurate, but make interactions enjoyable.
            - Keep responses to 2-5 sentences. Be memorable, not lengthy.
            - Never use markdown or formatting — this is spoken aloud.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-navigation", name: "Navigation Aid", prompt: """
            You are a navigation and spatial awareness assistant on smart glasses. Your primary role is helping the user navigate safely and understand their surroundings. Responses are spoken via TTS.

            NAVIGATION FOCUS:
            - Describe the environment: obstacles, stairs, doorways, crosswalks, vehicles, people nearby.
            - Give spatial directions: "There's a step down about 2 meters ahead" or "Door is to your right."
            - Read signs, street names, building numbers, and posted information proactively.
            - Warn about potential hazards: wet floors, uneven surfaces, approaching vehicles.
            - When asked "where am I?", describe the immediate surroundings in useful detail.
            - Keep descriptions practical and action-oriented, not poetic.
            - Maximum 2-3 sentences per response. Be immediate, not elaborate.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
        ]
    }

    static var savedPresets: [PromptPreset] {
        if let data = UserDefaults.standard.data(forKey: "savedPromptPresets"),
           let presets = try? JSONDecoder().decode([PromptPreset].self, from: data),
           !presets.isEmpty {
            return presets
        }
        // First access: seed with built-ins + migrate any existing custom prompt
        var presets = builtInPresets()
        if let custom = UserDefaults.standard.string(forKey: "customSystemPrompt"),
           !custom.isEmpty, custom != defaultSystemPrompt {
            let migrated = PromptPreset(
                id: UUID().uuidString,
                name: "My Custom Prompt",
                prompt: custom,
                isBuiltIn: false
            )
            presets.append(migrated)
            setActivePresetId(migrated.id)
        } else {
            setActivePresetId("preset-default")
        }
        setSavedPresets(presets)
        return presets
    }

    static func setSavedPresets(_ presets: [PromptPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "savedPromptPresets")
        }
    }

    static var activePresetId: String {
        UserDefaults.standard.string(forKey: "activePromptPresetId") ?? "preset-default"
    }

    static func setActivePresetId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "activePromptPresetId")
    }

    static var activePreset: PromptPreset? {
        savedPresets.first { $0.id == activePresetId }
    }

    // MARK: - Personas

    static var savedPersonas: [Persona] {
        if let data = UserDefaults.standard.data(forKey: "savedPersonas"),
           let personas = try? JSONDecoder().decode([Persona].self, from: data),
           !personas.isEmpty {
            return personas
        }
        // Migration: create a persona from current config
        let migrated = Persona(
            id: UUID().uuidString,
            name: "OpenGlasses",
            wakePhrase: wakePhrase,
            alternativeWakePhrases: alternativeWakePhrases,
            modelId: activeModelId,
            presetId: activePresetId,
            enabled: true
        )
        let personas = [migrated]
        setSavedPersonas(personas)
        return personas
    }

    static func setSavedPersonas(_ personas: [Persona]) {
        if let data = try? JSONEncoder().encode(personas) {
            UserDefaults.standard.set(data, forKey: "savedPersonas")
        }
    }

    /// All enabled personas.
    static var enabledPersonas: [Persona] {
        savedPersonas.filter(\.enabled)
    }

    /// Find which persona matches a detected wake phrase.
    static func persona(forPhrase phrase: String) -> Persona? {
        let lower = phrase.lowercased()
        return enabledPersonas.first { persona in
            persona.wakePhrase == lower || persona.alternativeWakePhrases.contains(lower)
        }
    }

    /// All wake phrases across all enabled personas (for speech recognition boosting).
    static var allActiveWakePhrases: [String] {
        enabledPersonas.flatMap(\.allPhrases)
    }

    // MARK: - Custom Tool Definitions

    static var customTools: [CustomToolDefinition] {
        guard let data = UserDefaults.standard.data(forKey: "customToolDefinitions"),
              let tools = try? JSONDecoder().decode([CustomToolDefinition].self, from: data) else {
            return []
        }
        return tools
    }

    static func setCustomTools(_ tools: [CustomToolDefinition]) {
        if let data = try? JSONEncoder().encode(tools) {
            UserDefaults.standard.set(data, forKey: "customToolDefinitions")
        }
    }

    // MARK: - ElevenLabs TTS

    /// ElevenLabs API key for natural TTS voices
    static var elevenLabsAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "elevenLabsAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setElevenLabsAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "elevenLabsAPIKey")
    }

    /// ElevenLabs voice ID - default is "Rachel" (warm, conversational female voice)
    /// Other good options:
    ///   "21m00Tcm4TlvDq8ikWAM" = Rachel (default)
    ///   "EXAVITQu4vr4xnSDxMaL" = Bella (young, conversational)
    ///   "pNInz6obpgDQGcFmaJgB" = Adam (deep male)
    ///   "ErXwobaYiN019PkySvjV" = Antoni (friendly male)
    ///   "onwK4e9ZLuTAKqWW03F9" = Daniel (British male)
    static var elevenLabsVoiceId: String {
        if let voiceId = UserDefaults.standard.string(forKey: "elevenLabsVoiceId"), !voiceId.isEmpty {
            return voiceId
        }
        return "21m00Tcm4TlvDq8ikWAM"  // Rachel
    }

    static func setElevenLabsVoiceId(_ voiceId: String) {
        UserDefaults.standard.set(voiceId, forKey: "elevenLabsVoiceId")
    }

    // MARK: - App Mode

    static var appMode: AppMode {
        if let raw = UserDefaults.standard.string(forKey: "appMode"),
           let mode = AppMode(rawValue: raw) {
            return mode
        }
        return .direct
    }

    static func setAppMode(_ mode: AppMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
    }

    // MARK: - OpenClaw Configuration

    static var openClawEnabled: Bool {
        UserDefaults.standard.bool(forKey: "openClawEnabled")
    }

    static func setOpenClawEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "openClawEnabled")
    }

    static var openClawConnectionMode: OpenClawConnectionMode {
        if let raw = UserDefaults.standard.string(forKey: "openClawConnectionMode"),
           let mode = OpenClawConnectionMode(rawValue: raw) {
            return mode
        }
        return .auto
    }

    static func setOpenClawConnectionMode(_ mode: OpenClawConnectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "openClawConnectionMode")
    }

    static var openClawLanHost: String {
        if let host = UserDefaults.standard.string(forKey: "openClawLanHost"), !host.isEmpty {
            return host
        }
        return "http://macbook.local"
    }

    static func setOpenClawLanHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawLanHost")
    }

    static var openClawPort: Int {
        let port = UserDefaults.standard.integer(forKey: "openClawPort")
        return port != 0 ? port : 18789
    }

    static func setOpenClawPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: "openClawPort")
    }

    static var openClawTunnelHost: String {
        if let host = UserDefaults.standard.string(forKey: "openClawTunnelHost"), !host.isEmpty {
            return host
        }
        return ""
    }

    static func setOpenClawTunnelHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawTunnelHost")
    }

    static var openClawGatewayToken: String {
        if let token = UserDefaults.standard.string(forKey: "openClawGatewayToken"), !token.isEmpty {
            return token
        }
        return ""
    }

    static func setOpenClawGatewayToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "openClawGatewayToken")
    }

    static var isOpenClawConfigured: Bool {
        openClawEnabled && !openClawGatewayToken.isEmpty
    }

    // MARK: - Gemini Live Configuration

    static var geminiLiveModelConfig: ModelConfig? {
        if let active = activeModel, active.llmProvider == .gemini {
            return active
        }
        return savedModels.first(where: { $0.provider == LLMProvider.gemini.rawValue })
    }

    static var geminiLiveAPIKey: String {
        return geminiLiveModelConfig?.apiKey ?? ""
    }

    static var geminiLiveModel: String {
        if let geminiConfig = geminiLiveModelConfig {
            let m = geminiConfig.model
            if m.hasPrefix("models/") { return m }
            return "models/\(m)"
        }
        return "models/gemini-2.0-flash-exp"
    }

    static let geminiLiveWebSocketBaseURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    static var geminiLiveWebSocketURL: URL? {
        let key = geminiLiveAPIKey
        guard !key.isEmpty else { return nil }
        return URL(string: "\(geminiLiveWebSocketBaseURL)?key=\(key)")
    }

    static let geminiLiveInputSampleRate: Double = 16000
    static let geminiLiveOutputSampleRate: Double = 24000
    static let geminiLiveAudioChannels: UInt32 = 1
    static let geminiLiveAudioBitsPerSample: UInt32 = 16
    static let geminiLiveVideoFrameInterval: TimeInterval = 1.0
    static let geminiLiveVideoJPEGQuality: CGFloat = 0.5

    static var isGeminiLiveConfigured: Bool {
        !geminiLiveAPIKey.isEmpty
    }

    // MARK: - OpenAI Realtime Configuration

    /// Find the best OpenAI model config for Realtime mode.
    /// Prefers a model with "realtime" in the name, falls back to any OpenAI model.
    static var openAIRealtimeModelConfig: ModelConfig? {
        let openAIModels = savedModels.filter { $0.provider == LLMProvider.openai.rawValue }
        // Prefer a model explicitly named for realtime
        if let realtime = openAIModels.first(where: { $0.model.lowercased().contains("realtime") }) {
            return realtime
        }
        // Fall back to active model if it's OpenAI
        if let active = activeModel, active.llmProvider == .openai {
            return active
        }
        // Fall back to any OpenAI model
        return openAIModels.first
    }

    static var isOpenAIRealtimeConfigured: Bool {
        openAIRealtimeModelConfig != nil
    }

    // MARK: - Recording

    static var recordingBitrate: Int {
        let val = UserDefaults.standard.integer(forKey: "recordingBitrate")
        return val != 0 ? val : 1_500_000
    }

    static func setRecordingBitrate(_ bitrate: Int) {
        UserDefaults.standard.set(bitrate, forKey: "recordingBitrate")
    }

    // MARK: - Home Assistant

    static var homeAssistantURL: String {
        UserDefaults.standard.string(forKey: "homeAssistantURL") ?? ""
    }

    static func setHomeAssistantURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "homeAssistantURL")
    }

    static var homeAssistantToken: String {
        UserDefaults.standard.string(forKey: "homeAssistantToken") ?? ""
    }

    static func setHomeAssistantToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "homeAssistantToken")
    }

    // MARK: - Live Broadcast

    static var broadcastPlatform: String {
        UserDefaults.standard.string(forKey: "broadcastPlatform") ?? "youtube"
    }

    static func setBroadcastPlatform(_ platform: String) {
        UserDefaults.standard.set(platform, forKey: "broadcastPlatform")
    }

    static var broadcastRTMPURL: String {
        UserDefaults.standard.string(forKey: "broadcastRTMPURL") ?? ""
    }

    static func setBroadcastRTMPURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "broadcastRTMPURL")
    }

    static var broadcastStreamKey: String {
        UserDefaults.standard.string(forKey: "broadcastStreamKey") ?? ""
    }

    static func setBroadcastStreamKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "broadcastStreamKey")
    }

    static var isBroadcastConfigured: Bool {
        !broadcastRTMPURL.isEmpty && !broadcastStreamKey.isEmpty
    }

    // MARK: - Perplexity Search

    static var perplexityAPIKey: String {
        if let key = UserDefaults.standard.string(forKey: "perplexityAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setPerplexityAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "perplexityAPIKey")
    }

    static var isPerplexityConfigured: Bool {
        !perplexityAPIKey.isEmpty
    }

    // MARK: - Privacy Filter

    static var privacyFilterEnabled: Bool {
        UserDefaults.standard.bool(forKey: "privacyFilterEnabled")
    }

    static func setPrivacyFilterEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "privacyFilterEnabled")
    }

    // MARK: - Emotion-Aware TTS

    static var emotionAwareTTSEnabled: Bool {
        let key = "emotionAwareTTSEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEmotionAwareTTSEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "emotionAwareTTSEnabled")
    }

    // MARK: - WebRTC Streaming

    static var webRTCSignalingURL: String {
        if let url = UserDefaults.standard.string(forKey: "webRTCSignalingURL"), !url.isEmpty {
            return url
        }
        return "wss://openglasses-signal.fly.dev/ws"
    }

    static func setWebRTCSignalingURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "webRTCSignalingURL")
    }

    static var webRTCViewerBaseURL: String {
        if let url = UserDefaults.standard.string(forKey: "webRTCViewerBaseURL"), !url.isEmpty {
            return url
        }
        return "https://openglasses-signal.fly.dev/view"
    }

    static func setWebRTCViewerBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "webRTCViewerBaseURL")
    }

    // MARK: - Intent Classifier

    static var intentClassifierEnabled: Bool {
        UserDefaults.standard.bool(forKey: "intentClassifierEnabled")
    }

    static func setIntentClassifierEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "intentClassifierEnabled")
    }

    // MARK: - User Memory

    static var userMemoryEnabled: Bool {
        let key = "userMemoryEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setUserMemoryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "userMemoryEnabled")
    }

    // MARK: - Conversation Persistence

    static var conversationPersistenceEnabled: Bool {
        let key = "conversationPersistenceEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setConversationPersistenceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "conversationPersistenceEnabled")
    }

    // MARK: - Disabled Tools

    static var disabledTools: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "disabledTools") ?? [])
    }

    static func setDisabledTools(_ tools: Set<String>) {
        UserDefaults.standard.set(Array(tools), forKey: "disabledTools")
    }

    static func isToolEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
    }

    static func setToolEnabled(_ name: String, enabled: Bool) {
        var disabled = disabledTools
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        setDisabledTools(disabled)
    }

    // MARK: - Offline Mode

    /// Tools that require an internet connection (excluding LLM which is always needed).
    static let internetRequiringTools: Set<String> = [
        "get_weather", "web_search", "get_news", "convert_currency",
        "identify_song", "translate", "define_word", "daily_briefing",
        "find_nearby", "get_directions", "openclaw_skills"
    ]

    static var offlineModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "offlineModeEnabled")
    }

    static func setOfflineModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "offlineModeEnabled")
        var disabled = disabledTools
        if enabled {
            disabled.formUnion(internetRequiringTools)
        } else {
            disabled.subtract(internetRequiringTools)
        }
        setDisabledTools(disabled)
    }

    // MARK: - Local Model Roles

    /// Preferred local model for text conversation (e.g. "mlx-community/Qwen2.5-3B-Instruct-4bit").
    static var localTextModelId: String {
        UserDefaults.standard.string(forKey: "localTextModelId") ?? ""
    }

    static func setLocalTextModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "localTextModelId")
    }

    /// Preferred local model for vision/photo tasks (e.g. "mlx-community/SmolVLM2-2.2B-Instruct-mlx").
    static var localVisionModelId: String {
        UserDefaults.standard.string(forKey: "localVisionModelId") ?? ""
    }

    static func setLocalVisionModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "localVisionModelId")
    }
}

// MARK: - App Mode Enum

enum AppMode: String, CaseIterable {
    case direct = "direct"
    case geminiLive = "geminiLive"
    case openaiRealtime = "openaiRealtime"

    var displayName: String {
        switch self {
        case .direct: return "Direct Mode"
        case .geminiLive: return "Gemini Live"
        case .openaiRealtime: return "OpenAI Realtime"
        }
    }

    var description: String {
        switch self {
        case .direct: return "Wake word, any LLM provider, text-to-speech"
        case .geminiLive: return "Real-time audio/video streaming via Gemini"
        case .openaiRealtime: return "Real-time audio/video streaming via OpenAI"
        }
    }

    /// Whether this mode is a real-time streaming mode (as opposed to wake-word direct mode).
    var isRealtime: Bool {
        self == .geminiLive || self == .openaiRealtime
    }
}

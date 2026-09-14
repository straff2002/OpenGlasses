import Foundation

/// A saved LLM model configuration.
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
    /// Per-model "small context": send a short spoken-style prompt and recent lines only — no
    /// tool list or full system prompt. A per-model choice because it exists for tight providers
    /// (Groq's 8k cap) and would cripple roomier ones. Optional so configs saved before the field
    /// existed decode as false. On-device providers ignore it — they always run the lean prompt.
    var smallContext: Bool? = nil

    /// Convenience to get the LLMProvider enum
    var llmProvider: LLMProvider {
        LLMProvider(rawValue: provider) ?? .custom
    }

    /// Whether this model should receive image input when the app has an image available.
    var visionEnabled: Bool {
        supportsVision ?? Self.inferredSupportsVision(provider: llmProvider, model: model, baseURL: baseURL)
    }

    /// Whether turns to this model use the lean prompt. False for configs from before the field.
    var smallContextEnabled: Bool { smallContext ?? false }

    static func inferredSupportsVision(provider: LLMProvider, model: String, baseURL: String) -> Bool {
        switch provider {
        case .anthropic, .gemini, .geminiVertex, .openai:
            return true
        case .chatgpt:
            // The subscription catalog is coding-tuned, and image acceptance on it was never
            // actually confirmed on device. Claiming vision here is what put a camera button in
            // front of a model that cannot use it, so the honest answer is no until a photo turn
            // is confirmed working against that backend. `ChatGPTVisionGate` is the backstop.
            return false
        case .groq, .local, .appleOnDevice:
            return false
        case .deepseek:
            // V4.1-Flash (`deepseek-flash`) accepts images, and the legacy `deepseek-v4-flash` /
            // `deepseek-v4-flash-vision-exp` IDs route to it. `deepseek-v4-pro` is its own
            // text-only model, so it must not match.
            let lowerModel = model.lowercased()
            return lowerModel.contains("flash") || lowerModel.contains("vision")
        case .mistral:
            return mistralVisionModels.contains(model.lowercased().trimmingCharacters(in: .whitespaces))
        case .qwen:
            // Qwen3.5-plus and qwen-vl models support vision
            let lowerModel = model.lowercased()
            return lowerModel.contains("vl") || lowerModel.contains("plus") || lowerModel.contains("max") || lowerModel.contains("omni")
        case .xai:
            // Grok 4 family is multimodal; earlier Grok text models are not
            let lowerModel = model.lowercased()
            return lowerModel.contains("grok-4") || lowerModel.contains("vision")
        case .openrouter:
            // OpenRouter supports vision for many models
            let lowerModel = model.lowercased()
            return lowerModel.contains("claude") || lowerModel.contains("gpt-4") || lowerModel.contains("gemini") || lowerModel.contains("vision") || lowerModel.contains("llava")
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

    /// Mistral model IDs its docs mark as taking image input: the vision guide's list (Large 3,
    /// Medium 3.1, Small 3.2, Ministral 3 3B/8B/14B), plus Medium 3.5 and Small 4, which their
    /// model cards and announcements describe as multimodal. Each ID is spelled exactly as a model
    /// card lists it, `-latest` aliases included. The dated names in the docs' page addresses
    /// (`mistral-medium-3-5-26-04`) are not API model IDs, so they are left out. An exact-match
    /// list, not a family substring: the same family names cover older text-only snapshots
    /// (`ministral-8b-2410`, `mistral-large-2411`), and Codestral, Devstral, OCR, Voxtral,
    /// moderation and embedding models don't take chat images at all. A model missing here can
    /// still be switched on per config.
    static let mistralVisionModels: Set<String> = [
        "mistral-large-2512", "mistral-large-latest",
        "mistral-medium-3-5", "mistral-medium-3", "mistral-medium-latest", "mistral-medium-2508",
        "mistral-small-2603", "mistral-small-latest", "mistral-small-2506",
        "ministral-3b-2512", "ministral-3b-latest",
        "ministral-8b-2512", "ministral-8b-latest",
        "ministral-14b-2512", "ministral-14b-latest",
    ]

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

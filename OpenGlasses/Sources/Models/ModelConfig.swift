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

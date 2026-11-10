import Foundation

/// The one line under Settings › Services › Web Search › "Let the AI search the web itself"
/// (Plan KZ, Outcome): who runs the current model's searches, and why. Pure over a decision.
enum ProviderSearchStatusLine {

    /// The company a provider's searches are billed by and refusals come from.
    static func vendor(of provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .xai: return "xAI"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .gemini, .geminiVertex: return "Google"
        default: return provider.displayName
        }
    }

    /// How the line names the model that searches.
    static func modelName(of kind: ProviderSearchSpec.Kind) -> String {
        switch kind {
        case .anthropic: return "Claude"
        case .openAIResponses: return "GPT"
        case .xaiResponses: return "Grok"
        case .gemini: return "Gemini"
        case .openRouter, .groq: return String(localized: "This model")
        }
    }

    static func line(for decision: ProviderSearchPolicy.Decision, provider: LLMProvider?,
                     model: String = "") -> String {
        guard let provider, provider != .local, provider != .appleOnDevice else {
            return String(localized: "On-device models use Avenkin's search.")
        }
        let vendor = vendor(of: provider)
        switch decision {
        case .provider(let spec):
            let name = modelName(of: spec.kind)
            let entry = SearchFeeTable.entry(for: spec.kind, model: model)
            if spec.kind == .gemini, let fee = entry.usdPer1000 {
                let price = SearchFeeTable.formatted(fee)
                return String(localized: "Gemini runs its own Google searches: about \(price) per 1,000 searches after 5,000 free a month, billed by Google. Google's search suggestions show under the reply.")
            }
            if let fee = entry.usdPer1000 {
                let price = SearchFeeTable.formatted(fee)
                return String(localized: "\(name) runs its own searches: about \(price) per 1,000 searches, billed by \(entry.billedBy).")
            }
            return String(localized: "\(name) runs its own searches, billed by \(entry.billedBy).")
        case .ourTool(let reason):
            switch reason {
            case .switchOff:
                return String(localized: "Off, so Avenkin's search is used.")
            case .wearerChoseEngine(let engine):
                return engine == "SearXNG"
                    ? String(localized: "Using your SearXNG server.")
                    : String(localized: "Using your \(engine) key.")
            case .medicalBoundary:
                return String(localized: "Medical Compliance mode keeps web search off.")
            case .vaultOnly:
                return String(localized: "A vault-only job doesn't search the web.")
            case .unsupported, .notDeclared:
                return String(localized: "This model can't search for itself, so Avenkin's search is used.")
            case .accountSignIn:
                return String(localized: "With an account sign-in, Avenkin's search is used.")
            case .refusedEarlier(.searchDisabled):
                return provider == .anthropic
                    ? String(localized: "Your Anthropic organisation has web search turned off, so Avenkin's search is used.")
                    : String(localized: "\(vendor) has web search turned off for this account, so Avenkin's search is used.")
            case .refusedEarlier(.workspaceLocked):
                return String(localized: "Your \(vendor) workspace doesn't allow this search, so Avenkin's search is used.")
            case .refusedEarlier(.toolUnsupported):
                return String(localized: "\(vendor) turned down its own search for this model, so Avenkin's search is used.")
            case .coolingOff:
                return String(localized: "\(vendor)'s search failed a moment ago, so Avenkin's search is used for a few minutes.")
            case .consentNotGiven:
                return String(localized: "Cloud AI Sharing doesn't allow web search with \(vendor), so Avenkin's search is used.")
            case .retryAfterRefusal:
                return String(localized: "\(vendor) turned down its own search, so Avenkin's search is used.")
            }
        }
    }
}

/// The policy's inputs read from the live settings, shared by the send paths and the
/// settings line so both decide the same way.
@MainActor
enum ProviderSearchLive {

    /// The configured search engine, in `WebSearchTool`'s own order.
    static var configuredEngine: String? {
        if Config.isPerplexityConfigured { return "Perplexity" }
        if Config.isTavilyConfigured { return "Tavily" }
        if Config.isBraveConfigured { return "Brave Search" }
        if Config.isSearXNGConfigured { return "SearXNG" }
        return nil
    }

    /// Whether this request goes with an account sign-in rather than a typed key.
    static func usesAccountSignIn(_ config: ModelConfig) -> Bool {
        switch config.llmProvider {
        case .anthropic: return AnthropicAuth.usesAccountSignIn(apiKey: config.apiKey)
        case .xai: return XAIAuth.usesAccountSignIn(apiKey: config.apiKey)
        case .chatgpt, .geminiVertex: return true
        default: return false
        }
    }

    static func inputs(for config: ModelConfig, credential: String, webSearchDeclared: Bool,
                       learnedResponsesRejection: Bool,
                       memory: ProviderSearchMemory = .shared) -> ProviderSearchPolicy.Inputs {
        ProviderSearchPolicy.Inputs(
            provider: config.llmProvider, model: config.model, baseURL: config.baseURL,
            switchOn: Config.providerWebSearchEnabled, configuredEngine: configuredEngine,
            hipaaMode: Config.hipaaMode,
            medicalLocalOnly: MedicalLLMRoutingPolicy.isEnforced(hipaaMode: Config.hipaaMode,
                                                                 localOnly: Config.hipaaLocalOnly),
            egressAllowsWebSearch: MedicalEgressGuard.allows(.webSearch),
            vaultOnlySealed: VaultOnlyPolicy.jobIsSealed,
            webSearchDeclared: webSearchDeclared,
            accountSignIn: usesAccountSignIn(config),
            learnedResponsesRejection: learnedResponsesRejection,
            memory: memory.reading(provider: config.llmProvider, credential: credential, model: config.model),
            country: Locale.current.region?.identifier)
    }

    /// The settings line for the active model.
    static func currentLine() -> String {
        guard let config = Config.activeModel else {
            return String(localized: "Add an AI model to use its own search.")
        }
        let decision = ProviderSearchPolicy.decide(
            inputs(for: config, credential: config.apiKey, webSearchDeclared: true,
                   learnedResponsesRejection: false))
        return ProviderSearchStatusLine.line(for: decision, provider: config.llmProvider, model: config.model)
    }

    /// The address a provider-run search travels to: the conversation host.
    static func origin(for config: ModelConfig) -> URL? {
        let base = config.llmProvider == .anthropic || config.baseURL.isEmpty
            ? config.llmProvider.defaultBaseURL : config.baseURL
        return URL(string: base)
    }
}

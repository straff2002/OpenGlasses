import Foundation

/// Plan GC P0 — which OpenAI endpoint a request goes to, at what reasoning level, and why.
///
/// # The problem
///
/// From GPT-5.4 onwards the provider's Chat Completions endpoint takes function tools only at
/// reasoning effort `none` (and `gpt-6-astra` / `gpt-6.1-sol` take no tools there at all). GB
/// therefore clamped every tool turn to `none`, so a technician who set a model to Medium got no
/// reasoning on exactly the turns that matter. The Responses API takes reasoning with tools.
///
/// # The rule (precedence order)
///
/// 1. Not the OpenAI provider → Chat Completions, unless the base URL names a Responses endpoint.
/// 2. OpenAI provider on a host other than `api.openai.com` (Azure, a proxy) → Chat Completions,
///    unless the base URL names a Responses endpoint (Decision 3: opt in by URL, no toggle).
/// 3. A model with no reasoning setting never moves.
/// 4. Responses refused this model earlier in the run → Chat Completions at `none` with tools
///    (this also overrides the URL opt-in of rules 1 and 2).
/// 5. No tools → Chat Completions, which carries `reasoning_effort` itself (Decision 2).
/// 6. A model that takes no tools on Chat Completions → Responses, even at Automatic.
/// 7. An explicit level above `none` with tools → Responses at that level (Decision 1).
/// 8. Explicit `none` → Chat Completions.
/// 9. Automatic with tools → Chat Completions at `none`: GB's cheap default, unchanged.
///
/// Pure and table-tested. `LLMService` consults it once per request before building the URL, and
/// the model editor shows the same selection, so what the tester reads is what goes on the wire.
enum OpenAIRouteSelector {

    enum Endpoint: String, Equatable {
        case chatCompletions, responses

        /// The editor's name for the endpoint.
        var label: String {
            switch self {
            case .chatCompletions: return "Chat Completions"
            case .responses: return "Responses API"
            }
        }

        /// The path appended to a base URL for this endpoint.
        var path: String {
            switch self {
            case .chatCompletions: return "/chat/completions"
            case .responses: return "/responses"
            }
        }
    }

    enum Reason: String, Equatable {
        /// An explicit level above `none` with tools → Responses.
        case reasoningWithTools
        /// The model takes no tools on Chat Completions → Responses even at Automatic.
        case chatToolsUnavailable
        /// Automatic with tools → Chat Completions at `none`.
        case automaticStaysCheap
        /// No tools → Chat Completions carries `reasoning_effort` itself.
        case noToolsAttached
        /// Level `none` → Chat Completions.
        case explicitNone
        case notReasoningModel
        /// Not the OpenAI provider.
        case otherProvider
        /// The OpenAI provider on a host other than `api.openai.com`, URL not naming `/responses`.
        case customHostChat
        /// The base URL's path ends in `/responses` → Responses.
        case customHostResponsesURL
        /// Responses refused this model earlier in this run → Chat Completions at `none`.
        case responsesRefusedEarlier

        /// One plain sentence for the model editor.
        var explanation: String {
            switch self {
            case .reasoningWithTools:
                return "This level needs the Responses API when tools are attached."
            case .chatToolsUnavailable:
                return "This model can't use tools on Chat Completions, so tool turns use the Responses API."
            case .automaticStaysCheap:
                return "Automatic keeps tool turns on Chat Completions without reasoning, to stay quick and cheap."
            case .noToolsAttached:
                return "Without tools, Chat Completions carries this setting itself."
            case .explicitNone:
                return "As set for this model."
            case .notReasoningModel:
                return "This model has no reasoning setting."
            case .otherProvider:
                return "This provider keeps its own request format."
            case .customHostChat:
                return "Custom hosts stay on Chat Completions unless the base URL names a Responses endpoint."
            case .customHostResponsesURL:
                return "The base URL names a Responses endpoint."
            case .responsesRefusedEarlier:
                return "The Responses API refused this model earlier, so tool turns use Chat Completions without reasoning until the app restarts."
            }
        }
    }

    struct Selection: Equatable {
        let endpoint: Endpoint
        /// The reasoning setting resolved for the chosen route.
        let reasoning: ReasoningPolicy.Resolution
        let reason: Reason
        /// False for a provider whose request format is neither of the two OpenAI endpoints
        /// (Anthropic, Gemini, on-device), so the editor does not name an endpoint it never uses.
        let namesEndpoint: Bool

        init(endpoint: Endpoint, reasoning: ReasoningPolicy.Resolution, reason: Reason,
             namesEndpoint: Bool = true) {
            self.endpoint = endpoint
            self.reasoning = reasoning
            self.reason = reason
            self.namesEndpoint = namesEndpoint
        }

        /// Content-free token for the trace and the privacy log: `responses` / `chatCompletions`.
        var token: String { endpoint.rawValue }

        /// Editor readout, e.g. "Medium · Responses API", "None · Chat Completions",
        /// "Not applicable".
        var displayValue: String {
            guard namesEndpoint, reasoning.effective != .notApplicable else { return reasoning.displayValue }
            return "\(reasoning.displayValue) · \(endpoint.label)"
        }
    }

    static let apiHost = "api.openai.com"
    static let defaultAPIBase = "https://api.openai.com/v1"

    static func select(provider: LLMProvider, model: String, baseURL: String,
                       toolsAttached: Bool, requested: String?,
                       learnedToolRejection: Bool = false,
                       learnedResponsesRejection: Bool = false) -> Selection {
        func resolve(_ route: ReasoningRoute, learned: Bool? = nil) -> ReasoningPolicy.Resolution {
            ReasoningPolicy.resolve(provider: provider, model: model, route: route,
                                    toolsAttached: toolsAttached, requested: requested,
                                    learnedToolRejection: learned ?? learnedToolRejection)
        }
        func chat(_ reason: Reason, learned: Bool? = nil) -> Selection {
            Selection(endpoint: .chatCompletions, reasoning: resolve(.chatCompletions, learned: learned), reason: reason)
        }
        func responses(_ reason: Reason) -> Selection {
            Selection(endpoint: .responses, reasoning: resolve(.responses), reason: reason)
        }

        // 1. Other providers keep their own shape; an OpenAI-compatible one may opt in by URL —
        //    unless that endpoint refused this model earlier in the run (4).
        guard provider == .openai else {
            let ownRoute = ReasoningRoute.route(for: provider)
            if ownRoute == .chatCompletions, baseURLNamesResponses(baseURL) {
                return learnedResponsesRejection
                    ? chat(.responsesRefusedEarlier, learned: true)
                    : responses(.customHostResponsesURL)
            }
            switch ownRoute {
            case .chatCompletions:
                return chat(.otherProvider)
            case .responses:   // the ChatGPT subscription backend, which only speaks Responses
                return Selection(endpoint: .responses, reasoning: resolve(.responses), reason: .otherProvider)
            case .anthropicMessages, .geminiREST, .geminiLive, .onDevice:
                return Selection(endpoint: .chatCompletions, reasoning: resolve(ownRoute),
                                 reason: .otherProvider, namesEndpoint: false)
            }
        }
        // 2. Azure and other hosts: Decision 3, opt in through the base URL.
        guard isOpenAIAPIHost(baseURL) else {
            guard baseURLNamesResponses(baseURL) else { return chat(.customHostChat) }
            return learnedResponsesRejection
                ? chat(.responsesRefusedEarlier, learned: true)
                : responses(.customHostResponsesURL)
        }
        // 3. Non-reasoning models (gpt-4o, gpt-4.1, gpt-5-chat-latest) never move.
        guard let family = ReasoningPolicy.openAIFamily(model: model) else {
            return chat(.notReasoningModel)
        }
        // 4. Refused on Responses earlier this run: Chat Completions, `none` with tools.
        if learnedResponsesRejection {
            return chat(.responsesRefusedEarlier, learned: true)
        }
        // 5. Chat Completions takes `reasoning_effort` fine without tools.
        guard toolsAttached else { return chat(.noToolsAttached) }
        // 6. No tools on Chat Completions at any level: Responses even at Automatic.
        if family.chatToolsUnavailable { return responses(.chatToolsUnavailable) }
        // 9. Automatic with tools: GB's clamp, quick and cheap.
        guard let explicit = requested.flatMap(ReasoningEffort.init(rawValue:)) else {
            return chat(.automaticStaysCheap)
        }
        // 7. An explicit level above `none` → Responses; 8. explicit `none` → Chat Completions.
        return explicit > ReasoningEffort.none ? responses(.reasoningWithTools) : chat(.explicitNone)
    }

    /// Host classification for the `.openai` provider: an empty base URL or host
    /// `api.openai.com` is the API host.
    static func isOpenAIAPIHost(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return URL(string: trimmed)?.host?.lowercased() == apiHost
    }

    /// Whether a base URL opts into Responses by naming the endpoint (path ends in `/responses`,
    /// trailing slash tolerated).
    static func baseURLNamesResponses(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(string: trimmed)?.path ?? trimmed
        return strippingTrailingSlashes(path).lowercased().hasSuffix("/responses")
    }

    /// The URL to POST to for the chosen endpoint, derived from the saved base URL (which may be
    /// `…/v1`, `…/v1/chat/completions`, `…/v1/responses` or an Azure `…/openai/v1`). An empty base
    /// is the API's default `https://api.openai.com/v1`.
    static func endpointURL(baseURL: String, endpoint: Endpoint) -> String {
        var base = strippingTrailingSlashes(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        if base.isEmpty { base = defaultAPIBase }
        for suffix in [Endpoint.chatCompletions.path, Endpoint.responses.path]
        where base.lowercased().hasSuffix(suffix) {
            base = strippingTrailingSlashes(String(base.dropLast(suffix.count)))
            break
        }
        return base + endpoint.path
    }

    private static func strippingTrailingSlashes(_ text: String) -> String {
        var text = text
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

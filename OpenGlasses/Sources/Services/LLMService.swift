import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Supported LLM providers
enum LLMProvider: String, CaseIterable {
    case anthropic = "anthropic"
    case openai = "openai"
    case chatgpt = "chatgpt"   // ChatGPT subscription (Codex OAuth) — Responses backend, no API key (Plan BW)
    case gemini = "gemini"
    case geminiVertex = "geminiVertex"   // Gemini via Vertex AI — Google OAuth, no API key (Plan AI)
    case groq = "groq"
    case deepseek = "deepseek"
    case mistral = "mistral"
    case zai = "zai"
    case qwen = "qwen"
    case minimax = "minimax"
    case xai = "xai"
    case openrouter = "openrouter"
    case custom = "custom"
    case local = "local"
    case appleOnDevice = "appleOnDevice"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        case .chatgpt: return "ChatGPT (Subscription)"
        case .gemini: return "Google (Gemini)"
        case .geminiVertex: return "Gemini (Vertex AI)"
        case .groq: return "Groq"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral AI"
        case .zai: return "Z.ai (Subscription)"
        case .qwen: return "Qwen (Subscription)"
        case .minimax: return "MiniMax (Subscription)"
        case .xai: return "xAI (Grok)"
        case .openrouter: return "OpenRouter (500+ models)"
        case .custom: return "Custom (OpenAI-compatible)"
        case .local: return "Local (On-Device MLX)"
        case .appleOnDevice: return "Apple Intelligence"
        }
    }

    /// Console URL where users can create/manage API keys.
    var consoleURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .geminiVertex: return URL(string: "https://console.cloud.google.com/apis/credentials")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .mistral: return URL(string: "https://admin.mistral.ai/plateforme/api-keys")
        case .minimax: return URL(string: "https://platform.minimaxi.com")
        case .xai: return URL(string: "https://console.x.ai")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .qwen: return URL(string: "https://dashscope.console.aliyun.com/apiKey")
        // The GLM Coding Plan on api.z.ai; a key from Zhipu's mainland console is refused there.
        case .zai: return URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .chatgpt, .custom, .local, .appleOnDevice: return nil
        }
    }

    /// Whether this provider uses the OpenAI-compatible API format
    var isOpenAICompatible: Bool {
        switch self {
        // .chatgpt speaks the Responses API, not chat completions — its own send path.
        case .anthropic, .gemini, .geminiVertex, .chatgpt, .local, .appleOnDevice: return false
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom: return true
        }
    }

    /// Default base URL for the provider
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .chatgpt: return ChatGPTOAuth.backendResponsesURL
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .geminiVertex: return ""   // built per-request from project/region (VertexAI.endpointURL)
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .mistral: return "https://api.mistral.ai/v1/chat/completions"
        case .zai: return "https://api.z.ai/api/coding/paas/v4/chat/completions"
        case .qwen: return "https://coding-intl.dashscope.aliyuncs.com/v1/chat/completions"
        case .minimax: return "https://api.minimax.io/v1/chat/completions"
        case .xai: return "https://api.x.ai/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        case .local: return ""
        case .appleOnDevice: return ""
        }
    }

    /// Default model for the provider.
    ///
    /// Each id was read against its provider's model list and retirement notices on 2026-10-10,
    /// and again on 2026-10-30 (Plan KA P2): Anthropic's current Sonnet, OpenAI's `gpt-5.4-mini`
    /// (`gpt-4o` shuts down 2027-01-14; `gpt-5.4-mini` has no shutdown date, takes images, and its
    /// tool turns already go out at reasoning `none`), Z.ai's flagship (`glm-4.5` is no longer in
    /// its chat model list) and MiniMax's (`MiniMax-M2.7` is no longer on its models page).
    /// A pinned id goes stale without anything in the app changing: when the provider retires it,
    /// a new user's first turn fails as though the key were wrong (`GeminiLiveModelPolicy` records
    /// the same failure on the live socket). Re-read this table when a provider announces a
    /// retirement, and prefer an id with no shutdown date over the newest one. `.custom` follows
    /// OpenAI's default, since its default address is OpenAI's; a server with its own model names
    /// replaces it in the form. OpenRouter follows Anthropic's current Sonnet (owner, 2026-10-30).
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-5.4-mini"
        case .chatgpt: return ChatGPTOAuth.defaultModel
        case .gemini: return "gemini-3.5-flash-lite"
        case .geminiVertex: return "gemini-3.5-flash-lite"
        case .groq: return "openai/gpt-oss-120b"
        case .deepseek: return "deepseek-flash"
        case .mistral: return "mistral-medium-latest"
        case .zai: return "glm-5.3"
        case .qwen: return "qwen3.7-plus"
        case .minimax: return "MiniMax-M3"
        case .xai: return "grok-4.7"
        case .openrouter: return "anthropic/claude-sonnet-5.5"
        case .custom: return "gpt-5.4-mini"
        case .local: return "mlx-community/gemma-4-e2b-it-4bit"
        case .appleOnDevice: return "apple-foundation-model"
        }
    }

    /// Whether the base URL field should be shown (editable endpoint)
    var showBaseURL: Bool {
        switch self {
        case .custom, .zai, .qwen, .minimax: return true
        default: return false
        }
    }

    /// Whether this provider requires an API key
    var requiresAPIKey: Bool {
        switch self {
        case .local, .appleOnDevice, .chatgpt, .geminiVertex: return false   // account sign-in, not a key
        default: return true
        }
    }

    /// Spoken/shown when a request reaches a provider with no credential. A fresh install can
    /// legitimately be here, so the copy always names both ways out rather than just failing.
    var missingCredentialMessage: String {
        switch self {
        case .anthropic:
            return "Anthropic API key not configured — add a key in Settings → Assistant → AI Models, sign in with Claude, or switch to on-device intelligence"
        case .xai:
            return "xAI API key not configured — add a key in Settings → Assistant → AI Models, sign in with xAI, or switch to on-device intelligence"
        default:
            return "\(displayName) API key not configured — add a key in Settings → Assistant → AI Models, or switch to on-device intelligence"
        }
    }

    /// Whether this provider supports listing models via API
    var supportsModelListing: Bool {
        switch self {
        case .local, .appleOnDevice, .geminiVertex: return false
        default: return true   // .chatgpt lists the signed-in account's live Codex catalog
        }
    }
}

/// Unified LLM service supporting Anthropic Claude and OpenAI-compatible APIs.
/// When OpenClaw is configured, includes tool definitions so the LLM can invoke the `execute` tool.
@MainActor
class LLMService: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var activeModelName: String = Config.activeModel?.name ?? "No Model"
    @Published var toolCallStatus: ToolCallStatus = .idle

    /// Last chain-of-thought reasoning from <think> tags (nil if none).
    /// Kept for the Prompt Inspector UI — never spoken aloud.
    @Published var lastReasoning: String?

    /// Plan KP P2: the suggested follow-ups the last `sendMessage` reply carried in its tail, which
    /// was taken off the reply (and its history entry) before anything else saw it. Empty when the
    /// reply had none. Reset as each `sendMessage` starts; the Direct turn reads it right after its
    /// call returns and hands it to the answer card, the only place follow-ups go.
    private(set) var replyFollowUps: [String] = []
    /// Plan KZ: the web pages this turn's reply rests on — cited by the provider's own search, or
    /// listed by our `web_search` — for the conversation's **Sources** and the answer card's line.
    /// Set during the turn, read the moment it returns, like `replyFollowUps`.
    private(set) var replyWebSources: [WebSource] = []
    /// Plan KZ: Google's Search Suggestions for this turn's grounded Gemini reply, stored with it.
    private(set) var replySearchSuggestions: SearchSuggestions?
    /// Plan KZ: what provider searches taught this install (refusals per account, the cool-off).
    var providerSearchMemory = ProviderSearchMemory.shared

    /// Optional OpenClaw bridge for tool calling in direct mode
    var openClawBridge: OpenClawBridge?

    /// Native tool router — when set, enables built-in tools (weather, timer, etc.)
    var nativeToolRouter: NativeToolRouter?

    /// Plan-then-execute narration hooks (Plan S), wired by AppState to the HUD/TTS. `onAgentNarrate`
    /// gets the plan header; `onAgentStep` gets per-step (index, total, step) progress.
    var onAgentNarrate: ((String) -> Void)?
    var onAgentStep: ((Int, Int, AgentStep) -> Void)?

    /// Local on-device LLM service (MLX Swift)
    var localLLMService: LocalLLMService?

    /// Resolve every LLM inference through the Medical Compliance routing rule. This is deliberately
    /// separate from `Config.activeModel`: a local-only turn must not mutate the user's saved model
    /// choice, and disabling the policy should immediately restore that choice.
    private func medicalInferenceModel(requested: ModelConfig) throws -> ModelConfig {
        var candidates = Config.savedModels
        if let local = localLLMService {
            // A downloaded model can be selected by the fast-tier agent without having a saved
            // `ModelConfig`. Give the policy a local config for every on-disk model so "usable"
            // means usable on this device, not merely present in the picker.
            let represented = Set(candidates.filter { $0.llmProvider == .local }.map(\.model))
            for modelID in local.downloadedModelIds() where !represented.contains(modelID) {
                candidates.append(ModelConfig(
                    id: "medical-local-\(modelID)", name: "On-Device Model",
                    provider: LLMProvider.local.rawValue, apiKey: "", model: modelID, baseURL: ""))
            }
        }

        let decision = MedicalLLMRoutingPolicy.decide(
            hipaaMode: Config.hipaaMode,
            localOnly: Config.hipaaLocalOnly,
            requested: requested,
            candidates: candidates,
            isUsableLocal: { [weak self] config in
                guard let service = self?.localLLMService else { return false }
                return service.isModelDownloaded(config.model)
                    || (service.isModelLoaded && service.loadedModelId == config.model)
            })
        switch decision {
        case .use(let config), .replaceWithLocal(let config):
            return config
        case .refuse:
            throw LLMError.invalidConfiguration(MedicalLLMRoutingPolicy.unavailableMessage)
        }
    }

    /// Defense at the actual remote-provider boundary. Selection points normally replace a cloud
    /// model before reaching this method; this guard makes a future direct caller fail closed.
    private func enforceMedicalRemoteBoundary(_ config: ModelConfig) throws {
        // Asked through the shared guard so inference is governed by the same rule as every other
        // route. The message stays the model-routing one: this refusal is about which *model* may
        // serve the request, and it already tells the wearer how to fix it.
        guard config.llmProvider != .local,
              config.llmProvider != .appleOnDevice,
              MedicalEgressGuard.blocks(.llmCompletion) else { return }
        throw LLMError.invalidConfiguration(MedicalLLMRoutingPolicy.unavailableMessage)
    }

    /// Backend-neutral local-inference seam (Plan DZ P0), built lazily around whatever
    /// `localLLMService` is set and used only while `Config.localRuntimeCoordinatorEnabled` is on.
    ///
    /// The coordinator's own background probe is left at its default here rather than reading
    /// `UIApplication`: `LocalLLMService.loadModel`/`generate` already refuse in the background
    /// with `LocalLLMError.backgrounded`, on the main actor where that state can be read safely, so
    /// the guard that keeps Metal work out of the background is unchanged and unduplicated. A
    /// runtime without such an internal guard supplies the probe when it lands.
    private var localCoordinator: LocalInferenceCoordinator?

    /// Test-only overrides for the on-device turn (Plan FC P1's containment harness).
    ///
    /// `sendLocal` resolves its model selection from `UserDefaults` and builds its coordinator over
    /// the real MLX backend, neither of which a headless test can supply: there is no Metal on the
    /// simulator, so a real generation cannot run there at all. These three fields are the seam that
    /// lets a test drive the *actual* turn — parsing, tool dispatch, regeneration, history — over a
    /// fake backend. Nil in production, and nothing in the app ever sets it.
    struct LocalTurnOverrides {
        var selectedID: LocalModelID?
        var installation: InstalledLocalModel?
        var coordinator: LocalInferenceCoordinator?
    }
    var localTurnOverridesForTesting: LocalTurnOverrides?

    private func coordinator(for service: LocalLLMService) -> LocalInferenceCoordinator {
        if let injected = localTurnOverridesForTesting?.coordinator { return injected }
        if let localCoordinator { return localCoordinator }
        // Both runtimes are registered; neither is *enabled* by registration. The GGUF backend
        // refuses every load with `.runtimeDisabled` while `Config.ggufModelsEnabled` is off, and
        // constructing it touches nothing native — so registering it here cannot change what an
        // MLX user's turn does, and the flag stays effective without a relaunch.
        let created = LocalInferenceCoordinator(backends: [
            MLXLocalInferenceBackend(service: service),
            LlamaCppLocalInferenceBackend(),
        ])
        localCoordinator = created
        return created
    }

    /// The coordinator, for surfaces that manage residency directly rather than through a turn —
    /// the model manager's Load/Unload and the deletion path.
    ///
    /// Returns nil only when there is no on-device service at all. Handing the manager the same
    /// coordinator the turn path uses is what keeps "at most one resident model" true across the
    /// two runtimes: a GGUF load from the manager evicts a resident MLX model instead of the two
    /// of them competing for the same memory.
    func localInferenceCoordinator() -> LocalInferenceCoordinator? {
        guard let localLLMService else { return nil }
        return coordinator(for: localLLMService)
    }

    /// Session the SSE streaming helpers use. Injectable purely so tests can stub `URLProtocol`
    /// and exercise the stream parsing/error paths headlessly (BM P9); production uses `.shared`.
    var streamingSession: URLSession = .shared

    /// Session the buffered (non-streaming) OpenAI-compatible request uses. Injectable for the same
    /// reason as `streamingSession`, so one fake transport serves both of Plan GC's routes.
    var dataSession: URLSession = .shared
    var processingConsent = CloudProcessingConsent.shared

    /// Where recorded usage goes. nil → `UsageTracker.shared`; a test injects a tracker over a
    /// scratch store so it can count what one turn recorded.
    var usageTrackerOverride: UsageTracker?

    /// The account sign-ins the subscription routes draw their tokens from. nil → the shared
    /// service; a test injects one over an in-memory store and a stubbed token endpoint, so a
    /// route's forced refresh on a 401 can be driven headlessly (Plan FG P1a).
    var claudeAccountOverride: ClaudeOAuthService?
    var chatGPTAccountOverride: ChatGPTOAuthService?
    var googleAccountOverride: GoogleOAuthService?
    var xaiAccountOverride: XAIOAuthService?

    private var claudeAccount: ClaudeOAuthService { claudeAccountOverride ?? .shared }
    private var chatGPTAccount: ChatGPTOAuthService { chatGPTAccountOverride ?? .shared }
    private var googleAccount: GoogleOAuthService { googleAccountOverride ?? .shared }
    private var xaiAccount: XAIOAuthService { xaiAccountOverride ?? .shared }


    /// The on-device turn's tool results, replayed when a full window rebuilds the session
    /// (`AppleToolResultCache`). Cleared at the start and end of every on-device turn.
    let appleToolResults = AppleToolResultCache()

    /// Said once per process: the first Field Assist job turn handed off the on-device model.
    private static var onDeviceJobRouteAnnounced = false
    /// Saved ChatGPT models already replaced at least once in this process: the wearer hears why
    /// on the first turn, not on every one.
    private static var announcedModelSubstitutions: Set<String> = []
    /// The cascade already routed this turn's job (`sendMessageCascading`): a later hop back to
    /// the on-device model stays there, with the compact job summary.
    private var onDeviceJobRouteSettled = false
    /// The sentence the cascade's routing owes the turn, for the configuration it routed to.
    private var pendingJobRouteNotice: (configId: String, notice: String)?
    /// The lead the last cascade hopped away from and the model that answered, so the next turns
    /// start there for a while instead of waiting out the same failure (`ModelCascadeMemory`).
    var cascadeMemory = ModelCascadeMemory()
    /// Set for the span of a cascading turn with more than one candidate: a provider's own
    /// transient retry is skipped in favour of the hop (`geminiRetryDelay`).
    private(set) var cascadeHasAlternative = false
    /// Whether the cascade has a candidate after the one being attempted: `cascadeHasAlternative`
    /// stays true on the last one, where giving up on a slow request would leave no answer at all.
    private(set) var cascadeHasNextCandidate = false

    #if canImport(FoundationModels)
    /// The Apple `Tool` adapters for the tool names last offered, rebuilt when the names change
    /// (Plan JD P0). The session itself is never cached — see `sendAppleOnDeviceImpl`.
    private var _appleToolCache: (names: [String], tools: Any)?
    @available(iOS 26.0, *)
    private var appleToolCache: (names: [String], tools: [any Tool])? {
        get { _appleToolCache.flatMap { cache in (cache.tools as? [any Tool]).map { (cache.names, $0) } } }
        set { _appleToolCache = newValue.map { ($0.names, $0.tools as Any) } }
    }
    #endif

    /// Conversation history for multi-turn context.
    /// No artificial turn limit — history persists for the full conversation session.
    /// Context window is managed by token-aware compaction, not a fixed turn count.
    private var conversationHistory: [[String: Any]] = []

    /// Maximum estimated tokens before compacting the context window.
    /// When exceeded, older messages are summarized and compressed rather than dropped blindly.
    private let maxEstimatedTokens = 80_000
    /// Plan GB P5: where the current job's conversation starts in `conversationHistory`, and the
    /// index of the current turn's user message — the request-copy budget's two anchors.
    private var jobHistoryFloor = JobHistoryFloor()
    private var turnHistoryStart = 0
    /// Older messages the last request copy left out (`APIHistoryBudget`), for its note.
    private var lastRequestOmittedMessages = 0
    /// Plan KK P2: what the last cloud request of the current turn carried, for the timeline pass.
    /// Nil until a turn builds a request copy, and reset at each turn's start, so a turn answered
    /// on the phone never hands the pass an older turn's counts.
    private(set) var lastTimelineReading: TimelineRequestReading?

    /// `completeStateless` calls in flight. Their requests run over an emptied history and say
    /// nothing about the conversation, so they never set the reading.
    private var statelessCallDepth = 0

    /// Record what a request kept, read from the copy actually sent. `omitted` is how many of the
    /// history's leading messages the copy left out (the copy is always a suffix of the history on
    /// the budgeted routes), so the turns left out after the floor are read from the history itself.
    @discardableResult
    private func noteTimelineReading(kept: [[String: Any]], omitted: Int = 0) -> TimelineRequestReading {
        let reading = timelineReading(kept: kept, omitted: omitted)
        if statelessCallDepth == 0 { lastTimelineReading = reading }
        return reading
    }

    private func timelineReading(kept: [[String: Any]], omitted: Int) -> TimelineRequestReading {
        TimelineRequestReading(
            keptUserTurns: TimelineRequestReading.realUserTurns(in: kept),
            historyUserTurns: TimelineRequestReading.realUserTurns(in: conversationHistory),
            floorDate: jobHistoryFloor.floorDate,
            omittedUserTurns: TimelineRequestReading.omittedUserTurns(
                in: conversationHistory, omitted: omitted,
                floor: jobHistoryFloor.floor(historyCount: conversationHistory.count)),
            clearedAt: jobHistoryFloor.historyClearedAt)
    }

    /// Plan KK P3: the active saved thread, as the timeline block reads it. Set by the app to read
    /// its conversation store; nil (tests that do not set it, a preview) carries no block. A narrow
    /// source on purpose: the service never holds the store.
    var timelineThreadSource: (@MainActor () -> TimelineRequestBlock.Thread?)?

    /// The request copy `requestHistory` last built, for `requestSystemParts` to settle its block.
    /// Reset by every `requestHistory`, so a block never outlives the copy it was counted for.
    private var pendingTimeline: TimelineRequestBlock.Request?
    /// Why the copy `requestHistory` last built may carry no block, before any counting.
    private var pendingTimelineSkip: TimelineRequestBlock.Skip?

    /// Plan KK P3: what the last conversation request did with the timeline, for the on-device
    /// Prompt Inspector only. Holds the block's text; never logged, never in a support report.
    @Published private(set) var lastTimelineDecision: TimelineRequestBlock.Decision?

    /// The active thread for a request to `provider`, or why its timeline stays out. The store is
    /// read only once the settings allow a block.
    private func timelineThread(for provider: LLMProvider) -> (thread: TimelineRequestBlock.Thread?,
                                                                 skip: TimelineRequestBlock.Skip?) {
        // A summary or planner call runs over an emptied history: it never carries a block.
        guard statelessCallDepth == 0 else { return (nil, .noThread) }
        let enabled = Config.conversationTimelineEnabled
        let hipaa = Config.hipaaMode
        let thread = enabled && !hipaa ? timelineThreadSource?() : nil
        if let skip = TimelineRequestBlock.gate(enabled: enabled, hipaaMode: hipaa, provider: provider,
                                                thread: thread) {
            return (nil, skip)
        }
        return (thread, nil)
    }

    /// Where the timeline starts in `messages` for the history as it stands (the job floor and
    /// the last clear), as the pass reads it.
    private func timelineFloor(in messages: [TimelineMessage]) -> Date? {
        TimelineRequestReading(keptUserTurns: 0, historyUserTurns: 0, floorDate: jobHistoryFloor.floorDate,
                               clearedAt: jobHistoryFloor.historyClearedAt)
            .timelineFloor(in: messages)
    }

    /// Settle a request's block and leave a record of it: the Prompt Inspector's copy, and a
    /// privacy-log line of counts and a reason (never the text) whenever something was left out.
    private func recordTimeline(_ decision: TimelineRequestBlock.Decision, omitted: Int) {
        guard statelessCallDepth == 0 else { return }
        // Every tool round settles one; publish only a change, so an open view is not redrawn
        // for each round of the same turn.
        if lastTimelineDecision != decision { lastTimelineDecision = decision }
        guard omitted > 0 else { return }
        PrivacyLog.conversation(.conversations, .timelineInRequest, count: decision.renderedCount,
                                tokens: decision.estimatedTokens, detail: PrivacyToken(decision.logToken))
    }

    /// Maximum tool call iterations to prevent infinite loops
    private let maxToolCallIterations = 5

    /// The guided job flow's "JOB DEBRIEF:" block while a debrief is running, else nil (Plan FO
    /// P3b). A closure because the prompt builder is static and the flow is owned by the app rather
    /// than being a singleton; the app sets it to `GuidedJobFlow.debriefBlock()` at launch.
    static var debriefContext: () -> String? = { nil }

    /// The device the wearer is talking through, for the identity line (Plan FY F3). A closure
    /// for the same reason as `debriefContext`: the prompt builders are static and the connection
    /// state is the app's, which sets this at launch from the glasses link it already tracks.
    /// Every route reads it **once**, where its prompt is assembled, and passes the result down —
    /// `AssistantIdentity` and `Config` never read device state themselves.
    static var deviceInUse: () -> AssistantIdentity.Device = { .phone }

    /// Build the full system prompt, optionally including location, tools, memory, and vision context.
    /// When `promptSections` is provided (from the ConversationClassifier), irrelevant sections are
    /// stripped to reduce token count. When nil, all sections are included (backward compatible).
    /// The lean system prompt for an on-device model: persona/behavior + location + memory, but
    /// NOT the ~100 native-tool descriptions (~8k tokens) that OOM a 2B model on a phone, and none
    /// of the heavy optional contexts (playbook/shortcuts/OpenClaw). `sendLocal` appends its own
    /// reduced tool block, so the model still has usable tools. Used by every on-device path
    /// (active-model `sendMessage` and fast-tier `sendViaLocalAgent`) so they can't diverge.
    static func leanOnDevicePrompt(locationContext: String?, memoryContext: String?, hasImage: Bool, turn: String, weatherContext: String? = nil, device: AssistantIdentity.Device = .phone) async -> String {
        var prompt = await buildSystemPrompt(
            locationContext: locationContext, includeTools: false, includeOpenClaw: false,
            hasImage: hasImage, memoryContext: memoryContext, turn: turn,
            compactMemoryRules: true, device: device).combined
        if let weatherContext {
            prompt += "\n\nCURRENT WEATHER (fetched just now — answer from this; do NOT call get_weather and do NOT say you will check): \(weatherContext)"
        }
        // Gemma-style templates have no separate system channel — this whole prompt is merged
        // into the model's first *user* turn, and a small model can flip roles and reply to
        // "OpenGlasses" instead of the wearer. Pin the speaker identity explicitly.
        let speaker = device == .glasses ? "the user wearing the glasses" : "the user"
        return prompt + "\n\nThe person speaking to you is \(speaker). Address them directly as \"you\". Never address \(Config.assistantName) — that is your own name."
    }

    /// The instructions for Apple's on-device model, built to fit its 4,096-token window
    /// (`AppleOnDeviceInstructions`): the persona, the short app guide and safety policy, a compact
    /// summary of an open job instead of its manuals, memory, the date and time and the location.
    /// Records its own blocks for the support report, so "sent:" names what this model was sent.
    static func appleOnDevicePrompt(locationContext: String?, memoryContext: String?,
                                    weatherContext: String? = nil,
                                    device: AssistantIdentity.Device = .phone) -> String {
        let speaker = device == .glasses ? "the user wearing the glasses" : "the user"
        let built = AppleOnDeviceInstructions.build(.init(
            persona: Config.systemPrompt(device: device),
            appGuide: SystemPromptBuilder.onDeviceAppGuide(appName: RegistrationFlow.appName),
            safetyPolicy: PromptInjectionPolicy.onDeviceSystemPromptPolicy,
            dateTime: currentDateTimeLine(),
            location: locationContext,
            memory: memoryContext,
            weather: weatherContext,
            job: Config.fieldAssistActive ? FieldSessionService.shared.activeSession.map(AppleOnDeviceInstructions.JobSummary.init(session:)) : nil,
            fieldAssistActive: Config.fieldAssistActive,
            modelSettingsPath: "Settings > \(SettingsHub.path(to: .intelligence))",
            speakerLine: "The person speaking to you is \(speaker). Address them directly as \"you\". Never address \(Config.assistantName) — that is your own name."))
        if built.memoryDroppedCharacters > 0, let memory = memoryContext {
            MemoryContextRecorder.noteClip(renderedCharacters: max(memory.count - built.memoryDroppedCharacters, 0),
                                           droppedCharacters: built.memoryDroppedCharacters)
        }
        TurnRecorder.notePromptBlocks(built.blocks)
        return built.text
    }

    static func leanCloudPrompt(hasImage: Bool, memoryContext: String? = nil, device: AssistantIdentity.Device = .phone) -> String {
        var prompt = """
        \(AssistantIdentity.line(name: Config.assistantName, role: "a voice assistant \(device.phrase). Replies are spoken aloud."))
        Answer in 1–2 short sentences. No markdown, lists, preamble, or follow-up questions.
        """
        if hasImage {
            prompt += "\n\n" + leanVisionBlock
        }
        if let memory = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            let clip = clipMemoryForLeanPrompt(memory)
            if clip.droppedCharacters > 0 {
                // Plan FC P3: this tier is the one place a prompt takes less memory than the store
                // rendered, so the turn's snapshot has to be corrected to what the backend saw.
                // Measured here, at the clip, rather than guessed at the call site, which does not
                // know which tier will answer.
                MemoryContextRecorder.noteClip(renderedCharacters: clip.text.count,
                                               droppedCharacters: clip.droppedCharacters)
            }
            prompt += "\n\nKnown about the wearer: \(clip.text)\n" + MemoryMannersPrompt.useLine
        }
        return prompt
    }

    /// What a short prompt says about an attached photo: the lean cloud tier's, and the condensed
    /// instructions' when a cloud model is fitted to a per-minute allowance (Plan KL P1).
    static let leanVisionBlock = """
        A photo from the camera is attached. You CAN see it — never deny vision.
        Name the main subject and anything asked. Skip background, lighting, and composition unless asked.
        If asked to read text: quote it verbatim; translate only if asked.
        """

    /// The condensed instructions a cloud model is given when the full ones do not fit the
    /// account's per-minute allowance (Plan KL P1, decision 4): the on-device path's own
    /// (`AppleOnDeviceInstructions`, persona, short app guide and safety policy, job summary,
    /// memory, date, time and location), without its line that manuals need a cloud model — this
    /// is the cloud model — plus the photo lines on a photo turn and the on-demand tool guide, so
    /// every tool is still one lookup away.
    static func condensedCloudPrompt(locationContext: String?, memoryContext: String?, hasImage: Bool,
                                     toolGuide: String, device: AssistantIdentity.Device = .phone)
        -> (text: String, blocks: [TurnTimeline.PromptBlock]) {
        let speaker = device == .glasses ? "the user wearing the glasses" : "the user"
        let built = AppleOnDeviceInstructions.build(.init(
            persona: Config.systemPrompt(device: device),
            appGuide: SystemPromptBuilder.onDeviceAppGuide(appName: RegistrationFlow.appName),
            safetyPolicy: PromptInjectionPolicy.onDeviceSystemPromptPolicy,
            dateTime: currentDateTimeLine(),
            location: locationContext,
            memory: memoryContext,
            weather: nil,
            job: Config.fieldAssistActive ? FieldSessionService.shared.activeSession.map(AppleOnDeviceInstructions.JobSummary.init(session:)) : nil,
            fieldAssistActive: Config.fieldAssistActive,
            modelSettingsPath: "Settings > \(SettingsHub.path(to: .intelligence))",
            speakerLine: "The person speaking to you is \(speaker). Address them directly as \"you\". Never address \(Config.assistantName) — that is your own name.",
            includesManualsNote: false))
        var text = built.text
        var blocks = built.blocks
        if hasImage {
            text += "\n\n" + leanVisionBlock
            blocks.append(.init(name: "photo", characters: leanVisionBlock.count + 2))
        }
        text += "\n\n" + toolGuide
        blocks.append(.init(name: "tools on demand", characters: toolGuide.count + 2))
        return (text, blocks)
    }

    /// How much of a rendered memory block the lean cloud tier carries.
    ///
    /// The tier exists for providers with a tight context ceiling (Groq's 8k), where the whole
    /// point is that the prompt stays small; the memory block is bounded upstream too
    /// (`SemanticMemoryStore.maxMemoryLines` / `maxValueChars`) but eight clamped values can still
    /// run past this. Named and separated from the prompt text so the clip is measurable rather
    /// than inferred from a diff of two prompts.
    nonisolated static let leanMemoryClipLimit = 400

    /// Clip a memory block to the lean tier's budget. Pure: returns the text the prompt will carry
    /// and how many characters of the block it no longer contains.
    ///
    /// `prefix` is grapheme-based, so a clip never splits a character — an emoji or a combining
    /// sequence either survives whole or is dropped whole.
    static func clipMemoryForLeanPrompt(_ memory: String,
                                        limit: Int = leanMemoryClipLimit) -> (text: String, droppedCharacters: Int) {
        guard memory.count > limit else { return (memory, 0) }
        return (String(memory.prefix(limit)) + "…", memory.count - limit)
    }

    static func leanVisionCloudPrompt(device: AssistantIdentity.Device = .phone) -> String {
        leanCloudPrompt(hasImage: true, device: device)
    }

    /// The memory block exactly as a full system prompt carries it: the rendered block itself,
    /// then the instructions that tell the model what to do with it.
    ///
    /// Extracted from `buildSystemPrompt` so what a turn *reports* injecting can be compared
    /// against what is injected (Plan FC P3) without reaching into a private method or rebuilding
    /// a whole prompt. The rendered block is appended verbatim — this tier never clips it — which
    /// is why `MemoryContextSnapshot.renderedCharacters` is the prompt's answer here as well.
    ///
    /// `compact` is the on-device form (Plan LN §5): the tags and the two-line manners, nothing
    /// else, for a model whose whole prompt has to fit a small window.
    static func memoryPromptBlock(_ memory: String, compact: Bool = false) -> String {
        var block = "\n\n\(memory)"
        if compact {
            block += "\n\nTo remember a fact the user shares, add [REMEMBER: key = value] to your reply; to forget one, [FORGET: key]. The tags are removed before speaking.\n"
                + MemoryMannersPrompt.shortForm
            return block
        }
        block += """


            MEMORY INSTRUCTIONS:
            You can remember facts about the user by including [REMEMBER: key = value] in your response.
            You can forget facts with [FORGET: key]. These tags will be stripped before speaking.
            Memories persist across all conversations — they are the bridge between sessions.

            Using memory:
            \(MemoryMannersPrompt.useRules.map { "- \($0)" }.joined(separator: "\n"))

            What to remember: names, preferences, family members, routines, interests, important dates, relationships, stated goals.
            Only remember when the user explicitly shares personal info — don't infer or assume.
            \(MemoryMannersPrompt.keepRules.map { "- \($0)" }.joined(separator: "\n"))

            Memory hygiene — keep memory accurate and compact:
            - Before adding a fact, check the existing memories listed above. If one already covers that key, update it rather than creating a duplicate.
            - Merge related facts when possible (e.g. "partner = Alex" plus "Alex's birthday is March 5" → update partner entry to include both).
            - For time-sensitive facts (e.g. "at the airport", "working on a presentation"), include a date or context so staleness can be evaluated later.
            - Use [FORGET: key] to remove facts the user corrects or that are clearly no longer true.
            - When the user says "forget X" or "that's wrong", always issue a [FORGET] command before storing the correction.
            """
        return block
    }

    /// Plan GB P5: returns the prompt as a `PromptLayout` — a stable head (persona, vision and tool
    /// guidance, safety policy) and a volatile tail (image instructions, memory, date and time,
    /// location, skills, job and manual context, …) — so a route that can place the tail after the
    /// history keeps its cacheable prefix byte-identical turn to turn. `.combined` is the old
    /// single string, head first.
    private static func buildSystemPrompt(locationContext: String?, includeTools: Bool, includeOpenClaw: Bool, hasImage: Bool, nativeToolNames: [String] = [], nativeToolDescriptions: [(name: String, description: String)] = [], onDemandToolGuide: String? = nil, gatewayToolNames: [String] = [], memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, turn: String? = nil, offersFollowUps: Bool = false, compactMemoryRules: Bool = false, device: AssistantIdentity.Device) async -> PromptLayout {
        // Agent personality mode: soul.md + skills.md + memory.md replace the standard prompt
        var prompt: String
        if Config.agentModeEnabled, let agentContext, !agentContext.isEmpty {
            prompt = agentContext
        } else {
            prompt = Config.systemPrompt(device: device)
        }

        // Support trace (2026-09-26): which blocks this prompt is made of, and how big each is.
        // Names and sizes only — the text itself never leaves this function through here.
        var blocks: [TurnTimeline.PromptBlock] = []
        var blockStart = 0
        // UTF-8 length, not `count`: constant time on a prompt that runs to tens of thousands of
        // characters, and the same as the character count for the English the blocks are made of.
        func closeBlock(_ name: String) {
            let size = prompt.utf8.count - blockStart
            if size > 0 { blocks.append(.init(name: name, characters: size)) }
            blockStart = prompt.utf8.count
        }
        closeBlock(Config.agentModeEnabled && !(agentContext ?? "").isEmpty ? "agent persona" : "system prompt")

        // Helper: check if a section should be included. When promptSections is nil (no classifier), include everything.
        let shouldInclude: (ConversationClassifier.PromptSections) -> Bool = { section in
            guard let sections = promptSections else { return true }
            return sections.contains(section)
        }

        // Ensure vision awareness is always present, even if user has a custom system prompt
        if shouldInclude(.vision) && !prompt.lowercased().contains("vision") && !prompt.lowercased().contains("camera") {
            prompt += """

            VISION & CAMERA:
            - \(Config.cameraSentence) When the user says "look at this", "what is this", "read this", "identify this", "take a photo", or similar, a photo will be captured and sent to you automatically.
            - You CAN see images — never say you lack camera or vision access.
            - Keep vision answers to 1–2 short sentences. Name the main subject. Skip background, lighting, and composition unless asked.
            - For text/signs/menus in foreign languages: transcribe the original text, then translate it.
            - For objects, products, landmarks: identify them briefly — do not catalog every detail.
            - After reading text from an image, offer to copy it to clipboard or translate it.
            """
        }

        closeBlock("vision guidance")

        // Where the assistant's own settings live. Unconditional and in the stable head: a question
        // about the app matches no classifier section, and the text never changes turn to turn.
        prompt += "\n\n" + SystemPromptBuilder.appGuide(appName: RegistrationFlow.appName)
        closeBlock("app guide")

        if includeTools && shouldInclude(.tools) {
            var toolSection = """


            TOOLS:
            You have access to the following tools. Use the appropriate tool when the user's request matches its capability.
            """

            if !nativeToolNames.isEmpty {
                toolSection += "\nBuilt-in tools: \(nativeToolNames.joined(separator: ", "))."
                // Plan BG P1: the per-tool descriptions are generated from each NativeTool's own
                // `description` (the same source as the machine-readable tool schemas), so this
                // list can't drift from the real tool set or from the Gemini Live prompt.
                if !nativeToolDescriptions.isEmpty {
                    toolSection += "\n\n" + SystemPromptBuilder.toolLines(nativeToolDescriptions)
                }
                // Plan IU: on-demand definitions — how to get one, and a summary of every tool that
                // may need looking up. Nil on full exposure, so that prompt is byte-for-byte as before.
                if let onDemandToolGuide {
                    toolSection += "\n\n" + onDemandToolGuide
                }
                // Plan BM P4: domains the model must route through a tool, never self-answer.
                let routingRules = SystemPromptBuilder.routingRules(
                    toolNames: nativeToolNames, hiddenTrades: FieldTradeGate.promptHiddenTrades)
                if !routingRules.isEmpty {
                    toolSection += "\n\nMANDATORY ROUTING:\n" + routingRules
                }

                // Inject user-defined custom tool descriptions
                // A vault-only job lists none: a custom tool is an HTTP call the app never reviewed.
                let customTools = VaultOnlyPolicy.jobIsSealed ? [] : Config.customTools.filter { Config.isToolEnabled($0.name) }
                for ct in customTools {
                    toolSection += "\n            - \(ct.name): \(ct.description)"
                }

                // Inject the user's Siri Shortcuts so run_shortcut targets real names (Plan Z)
                if let shortcuts = shortcutsContext {
                    toolSection += "\n\n            \(shortcuts.replacingOccurrences(of: "\n", with: "\n            "))"
                }

                // Inject Home Assistant device list so LLM uses real entity IDs (skip if classifier says not needed)
                if shouldInclude(.homeAssistant),
                   let haSummary = await HomeAssistantEntityCache.shared.deviceSummaryForPrompt() {
                    toolSection += "\n\n            \(haSummary.replacingOccurrences(of: "\n", with: "\n            "))"
                }
            }

            if includeOpenClaw && shouldInclude(.openClaw) {
                toolSection += """

            OPENCLAW GATEWAY:
            You also have an "execute" tool that connects to OpenClaw — a powerful personal assistant \
            running on the user's computer. It has access to their files, browser, apps, messages, \
            notes, calendar, contacts, and everything on their machine. It knows things about the \
            user that you don't.
            \(!gatewayToolNames.isEmpty ? "\nAvailable gateway skills: \(gatewayToolNames.joined(separator: ", ")).\nUse execute with the matching skill name for these capabilities." : "")
            Use execute when:
            - Built-in tools can't handle the request
            - The user asks about personal info, preferences, or history you don't have
            - Sending messages on any platform (WhatsApp, Telegram, Slack, email, etc.)
            - Complex research, drafting, or multi-step tasks
            - Controlling apps, services, or external integrations
            - Remembering or recalling anything beyond your conversation context

            NEVER say "I don't know anything about you" — ask OpenClaw via execute instead. \
            If you're unsure whether you can handle something, use execute. It's your extension.
            """
            }

            // Examples name only what the turn offers: told to call `web_search`, a vault-only job's
            // model would, and the trace of a sealed job would carry the refusal (Plan KE).
            let searchExamples = nativeToolNames.contains("web_search") ? """

               - "Got it, searching for that now." then call web_search.
               - "One moment, looking that up." then call web_search.
            """ : ""
            // Plan LA §3: with Quiet After Actions on, an action-only request skips the preamble so
            // a quiet turn is not "Turning off the lights" and then a tone.
            let quietActionsException = QuietAfterActionsPrompt.exception(
                enabled: Config.quietAfterActionsEnabled, simpleMode: Config.simpleModeEnabled)
            toolSection += """

            TOOL USAGE RULES:
            CRITICAL: NEVER tell the user a tool is "not configured" or "not set up" — ALWAYS call the tool and let it handle errors. The tools check configuration internally and return helpful messages. Your job is to call them, not to guess their state.
            1. ALWAYS speak a brief verbal acknowledgment BEFORE calling any tool. This prevents awkward \
            silence while the tool executes. Examples:
               - "Sure, let me check the weather." then call get_weather.\(searchExamples)\(quietActionsException)
            2. CONTACTS: phone_call and send_message both accept contact NAMES directly (e.g. "Mom", "John"). \
            They automatically resolve names to phone numbers from the user's contacts. You do NOT need to call \
            lookup_contact first — just pass the name. If multiple matches exist, the tool returns options for the user to choose. \
            Only use lookup_contact when the user explicitly asks "what's someone's number?" without wanting to call or text.
            3. MULTI-STEP CHAINS: You can call multiple tools in sequence. After receiving a tool result, \
            you may call another tool before responding. Examples:
               - "Call the nearest pharmacy" → find_nearby (find pharmacy) → phone_call (call the number)
               - "How do I get to John's house?" → lookup_contact (get address) → get_directions (navigate)
               - "Save what that sign says" → (read image text) → copy_to_clipboard (save it)
            4. The calendar proactive alert system will automatically notify the user 10 minutes before events. \
            You do NOT need to remind them about upcoming events unless they ask.
            5. FALLBACK TO OPENCLAW: If a built-in tool fails or you don't have the info the user needs, \
            use execute (OpenClaw). It has 56+ skills and access to the user's full computer. \
            NEVER tell the user something can't be done or that you don't know — try OpenClaw first.
            """

            prompt += toolSection
        }
        closeBlock("tools")
        // Plan GB P5: everything above is the stable head; everything below changes turn to turn
        // (the safety policy, appended last, rejoins the head in `PromptLayout.split`).
        let stableHeadBytes = prompt.utf8.count
        if hasImage {
            prompt += """


            VISION INPUT:
            This turn includes an image captured from the user's camera. You can analyze that image for this response.
            Do not say you lack camera or image access when an image is attached. If the image is unclear, say what you can and cannot make out.

            IDENTIFY & OCR:
            When the user asks to "identify", "read", "OCR", or "what does this say", carefully read ALL text visible in the image.
            - For signs, menus, labels, documents: transcribe the text accurately.
            - For foreign language text (e.g. Japanese, Chinese, Korean, Arabic, etc.): first transcribe the original text, then provide a translation into the user's language (English by default). Format as: "[Original text] — [Translation]".
            - For objects, products, landmarks: describe what you see and identify it.
            - For barcodes/QR codes: note their presence even if you can't decode them.
            """
        }
        closeBlock("image instructions")
        if let memory = memoryContext {
            prompt += Self.memoryPromptBlock(memory, compact: compactMemoryRules)
        }
        closeBlock("memory")
        if let playbook = playbookContext {
            prompt += "\n\n\(playbook)"
        }
        closeBlock("playbook")
        // Models have no clock — without this one ~15-token line they answer date/time
        // reasoning from their training cutoff, confidently wrong ("local LLM doesn't
        // know day or time"). Unconditional: cheap enough for every turn, both paths.
        prompt += "\n\nCURRENT DATE & TIME: \(Self.currentDateTimeLine())"
        closeBlock("date and time")

        if let location = locationContext {
            prompt += "\n\nUSER LOCATION: \(location)"
        }
        closeBlock("location")
        if let nowPlaying = nowPlayingContext {
            prompt += "\n\n\(nowPlaying)"
        }
        closeBlock("now playing")
        // Inject voice-taught skills
        if shouldInclude(.tools), let skills = VoiceSkillStore.shared.promptContext(for: turn) {
            prompt += "\n\n\(skills)"
        }
        closeBlock("voice skills")
        // Inject Field Assist vault content when a session is active.
        // This grounds the LLM in domain knowledge (refrigeration, IT, health) with strict source attribution.
        if let vaultContext = FieldSessionService.shared.promptContext(turn: turn) {
            prompt += "\n\n<field_assist_context>\n\(vaultContext)\n</field_assist_context>"
        }
        closeBlock("field assist: vault, job and manual passages")
        if let manuals = PersonalManualLibrary.shared.promptContext {
            prompt += "\n\n" + manuals
        }
        closeBlock("selected personal manuals")
        // Inject the debrief block while one is running (Plan FO P3b): which job it is about and
        // what the model may not do during one. Outside the vault context on purpose — a debrief
        // usually runs on a finished job, with no session active and no vault loaded.
        if let debrief = debriefContext() {
            prompt += "\n\n\(debrief)"
        }
        closeBlock("job debrief")
        // Inject the active project's knowledge-base grounding when it has documents (Plan AN).
        if let projectContext = ProjectContextService.shared.promptContext() {
            prompt += "\n\n\(projectContext)"
        }
        closeBlock("project documents")
        // Inject the pages read so far when a reading session is live (Plan BT). Ungated by the
        // classifier on purpose: mid-book questions ("who is she?") match no keyword list, so the
        // live session is the signal — same call the playbook context makes. Here rather than as a
        // threaded parameter because this function is on every path (the lean on-device prompt
        // included), so local, cloud and cloud-agent all get it from this one line. The turn lets
        // the P4 catch-up retrieval pick which confirmed-read earlier passages ride along.
        if let readingContext = ReadingCompanionService.shared.promptContext(turn: turn) {
            prompt += "\n\n\(readingContext)"
        }
        closeBlock("reading session")
        // Inject project-scoped notes for the active job (what the user is mid-way through).
        if Config.fieldAssistActive, Config.projectMemoryEnabled,
           let session = FieldSessionService.shared.activeSession, session.isActive {
            let eligible = ProjectMemoryScope.eligible(
                BrainStore.shared.projectMemories(for: session.id), activeProject: session.id)
            let block = ProjectMemoryFormatter.block(eligible)
            if !block.isEmpty { prompt += "\n\n\(block)" }
        }
        closeBlock("job notes")
        // Inject social context (people the user knows) — already in the untrusted-data envelope
        // saved memory uses (Plan LN §4).
        if shouldInclude(.social), let social = SocialContextStore.shared.promptContext() {
            prompt += "\n\n\(social)"
        }
        closeBlock("people")
        // Inject installed ClawHub skills
        if shouldInclude(.openClaw), let skillContext = InstalledSkillStore.shared.promptContext(for: turn) {
            prompt += "\n\n\(skillContext)"
        }
        closeBlock("installed skills")
        // Plan KP P2: the follow-up tail, asked for only while answers are shown on a display (or
        // the mirror) and its setting is on. In the volatile tail: the display comes and goes, and
        // the cacheable head must not move with it. Cloud prompts only (`offersFollowUps`).
        if offersFollowUps, let clause = FollowUpPrompt.clauseForPrompt() {
            prompt += "\n\n" + clause
        }
        closeBlock("follow-ups")
        // Always append the prompt-injection / untrusted-content policy. This is a security
        // baseline — it is never stripped by the classifier and applies in every mode.
        prompt += PromptInjectionPolicy.systemPromptPolicy
        closeBlock("safety policy")
        TurnRecorder.notePromptBlocks(blocks)
        return PromptLayout.split(prompt, stableHeadBytes: stableHeadBytes,
                                  trailingStable: PromptInjectionPolicy.systemPromptPolicy)
    }

    /// Frame a tool result before feeding it back to the model. Output from tools that return
    /// untrusted external content (web, OCR, captions, gateway, MCP, …) is wrapped in a labelled
    /// envelope so injected instructions inside it are visibly framed as data, not commands.
    private func wrapToolResultForModel(toolName: String, content: String) -> String {
        let isKnownNative = nativeToolRouter?.registry.tool(named: toolName) != nil
        guard PromptInjectionPolicy.isUntrustedOutput(toolName: toolName, isKnownNativeTool: isKnownNative) else {
            return content
        }
        return PromptInjectionPolicy.wrap(toolName: toolName, content: content)
    }

    // MARK: - On-demand tool schemas (Plan IU)

    /// Tools this conversation has used or looked up. Under core exposure they are declared in
    /// full from the next model round on, so a tool the model reached once stays reachable without
    /// another lookup. Cleared with the conversation.
    private(set) var toolExposureMemory: Set<String> = []

    /// Decide this turn's exposure and log it — counts and tokens only.
    private func resolveToolExposure(config: ModelConfig, includeOpenClaw: Bool) -> ToolExposureTurn {
        let registry = nativeToolRouter?.registry
        let available = ToolDeclarations.availableToolSet(registry: registry, mcpClient: nativeToolRouter?.mcpClient)
        let provider = config.llmProvider
        let catalogContext = provider == .chatgpt
            ? ChatGPTContextCatalog.context(model: config.model, accountID: ChatGPTOAuthService.shared.accountID)
            : nil
        let window = ModelContextWindow.resolve(provider: provider, model: config.model,
                                                baseURL: config.baseURL, chatGPTCatalogContext: catalogContext)
        let core = ToolExposureCore.names(fieldJobActive: FieldToolProfile.fieldJobActive,
                                          accessibilityMode: Config.accessibilityModeEnabled,
                                          vaultOnly: VaultOnlyPolicy.jobIsSealed)
        let decision = ToolExposurePolicy.decide(mode: Config.toolDefinitionsMode, available: available.names,
                                                 fullSetBytes: available.bytes, contextWindow: window?.tokens,
                                                 core: core, remembered: toolExposureMemory)
        // Schemas the first request carries: the declared set, the lookup tool when on demand,
        // and OpenClaw's `execute`, which is never on demand.
        let lookup = decision.exposure == .core && registry?.tool(named: ToolLookupTool.toolName) != nil ? 1 : 0
        let gateway = includeOpenClaw ? 1 : 0
        PrivacyLog.model(.toolExposure, provider: PrivacyToken(provider.rawValue),
                         model: PrivacyToken(config.model),
                         count: decision.declared.count + lookup + gateway,
                         total: decision.available.count + gateway,
                         tokens: decision.fullSetTokens,
                         detail: PrivacyToken(decision.exposure.rawValue),
                         reason: PrivacyToken(decision.reason.rawValue))
        return ToolExposureTurn(decision: decision)
    }

    /// The prompt's on-demand block for a core-exposure turn, nil on full exposure.
    /// - Parameter core: the tools the block leaves out because they are declared in full; nil for
    ///   this turn's core set. A request fitted to a per-minute allowance empties it (Plan KL P1),
    ///   so every tool is listed.
    private func onDemandToolGuide(for decision: ToolExposureDecision, nativeToolNames: [String],
                                   core: Set<String>? = nil) -> String? {
        guard decision.exposure == .core, let registry = nativeToolRouter?.registry else { return nil }
        let core = core ?? ToolExposureCore.names(fieldJobActive: FieldToolProfile.fieldJobActive,
                                                  accessibilityMode: Config.accessibilityModeEnabled,
                                                  vaultOnly: VaultOnlyPolicy.jobIsSealed)
        let native = registry.toolDescriptions(for: nativeToolNames.filter { decision.available.contains($0) && !core.contains($0) })
        let nativeSet = Set(nativeToolNames)
        let mcpNames = decision.available.subtracting(nativeSet).sorted()
        return SystemPromptBuilder.onDemandToolGuide(native: native, mcpNames: mcpNames)
    }

    /// The names this model round declares — nil for every tool — recorded on the turn so the
    /// dispatcher's safety net judges a call against the list it was written against.
    private func roundToolFilter() -> Set<String>? {
        guard let turn = ToolExposureScope.turn else { return nil }
        let names = ToolExposurePolicy.roundDeclared(turn.decision, promoted: toolExposureMemory)
        turn.declaredThisRound = names
        return names
    }

    /// The tool loop's round limit. A turn on demand may spend a round looking a tool up and one
    /// on a call the safety net turned back, so it gets two more.
    private var toolLoopIterations: Int {
        ToolExposureScope.turn?.decision.exposure == .core ? maxToolCallIterations + 2 : maxToolCallIterations
    }

    /// Promote `names` for the rest of the conversation, logging how many were new.
    private func promoteTools(_ names: [String], reason: String) {
        let added = names.filter { !toolExposureMemory.contains($0) }
        guard !added.isEmpty else { return }
        toolExposureMemory.formUnion(added)
        PrivacyLog.model(.toolExposure, count: added.count, detail: PrivacyToken("added"),
                         reason: PrivacyToken(reason))
    }

    /// The shared tool-dispatch step used by every provider's tool loop (Plan BG P3): native tools
    /// via `NativeToolRouter`, else the OpenClaw bridge, else a failure. Status transitions flow to
    /// the published `toolCallStatus`. Yield detection and the parse-error path live in the
    /// `ToolDispatcher` value type so the whole step is unit-testable with a mock executor.
    private func makeToolDispatcher() -> ToolDispatcher {
        ToolDispatcher(
            execute: { [weak self] name, args, rawArgs, callID in
                guard let self else {
                    return .failedBeforeExecution(reason: "Service unavailable")
                }
                // Plan KL P1: counted before anything else, so a retry can tell a call was made —
                // and entered in the turn's ledger, so a hop can tell what it did (P2).
                self.toolCallsDispatched += 1
                let ledgerID = self.ledgerDispatched(name, args: args)
                // Plan IU safety net: a call to a tool the model may have but whose definition this
                // round did not carry is not run on arguments written without the schema. Nothing
                // happens, the definition rides on the next request, and the model calls again.
                if let turn = ToolExposureScope.turn,
                   ToolExposurePolicy.isUndeclaredCall(name, declaredThisRound: turn.declaredThisRound,
                                                       available: turn.decision.available) {
                    self.promoteTools([name], reason: "undeclaredCall")
                    TurnRecorder.noteToolCall(name: self.nativeToolRouter?.registry.tool(named: name) != nil
                                                  ? name : "unrecognised tool",
                                              outcome: "not declared")
                    let refused = ToolExecutionOutcome.failedBeforeExecution(
                        reason: ToolExposurePolicy.undeclaredCallMessage(name))
                    self.turnToolLedger.finished(ledgerID, outcome: refused)
                    return refused
                }
                let toolTraceID = TurnRecorder.toolTraceID
                let outcome: ToolExecutionOutcome
                // Plan LA: what a native tool said about its request landing, beside its outcome.
                var completion: ActionCompletion?
                if let router = self.nativeToolRouter {
                    // The provider's own call id, where it gave one: a redelivery of this exact
                    // call then resolves to the operation that already ran instead of running again.
                    (outcome, completion) = await ActionCompletionReport.collect {
                        await router.executeRoot(name: name, args: args, origin: .model,
                                                 invocationID: callID ?? UUID().uuidString)
                    }
                } else if let bridge = self.openClawBridge, Config.isOpenClawAgentActive,
                          !VaultOnlyPolicy.jobIsSealed {
                    let taskDesc = args["task"] as? String ?? (rawArgs ?? String(describing: args))
                    outcome = ToolExecutionOutcome(
                        await bridge.delegateTask(task: taskDesc, toolName: name))
                } else {
                    outcome = .failedBeforeExecution(reason: "No tool handler available")
                }
                self.turnToolLedger.finished(ledgerID, outcome: outcome, completion: completion)
                // Plan KZ: the pages our own search listed are the reply's sources too, so the
                // phone shows the same Sources list whichever search ran.
                if name == ProviderSearchPolicy.ourToolName, case .completed = outcome {
                    self.addReplyWebSources(ProviderSearchEvidence.ourToolSources(fromResult: outcome.text))
                }
                // Support trace: only web_search keeps a bounded, redacted query and result.
                // Unknown tool names and all other arguments/outputs remain unrecorded.
                let known = self.nativeToolRouter?.registry.tool(named: name) != nil
                TurnRecorder.noteToolResult(name: known ? name : "unrecognised tool",
                                            outcome: LLMService.traceOutcome(outcome),
                                            query: args["query"] as? String, result: outcome.text,
                                            turnID: toolTraceID)
                // Plan IU: what a lookup returned, and any tool the model reached, stay declared for
                // the rest of the conversation.
                if let available = ToolExposureScope.turn?.decision.available {
                    if name == ToolLookupTool.toolName, case .completed = outcome {
                        self.promoteTools(ToolLookupTool.returnedNames(
                            requested: ToolExposurePolicy.requestedNames(args), declarable: available),
                                          reason: "lookup")
                    } else if available.contains(name) {
                        self.toolExposureMemory.insert(name)
                    }
                }
                return outcome
            },
            onStatus: { [weak self] status in self?.toolCallStatus = status }
        )
    }

    /// The class of a tool's result, for the support trace.
    private static func traceOutcome(_ outcome: ToolExecutionOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .rejected: return "refused"
        case .failedBeforeExecution: return "failed"
        case .outcomeUnknown: return "outcome unknown"
        }
    }

    /// - Parameter onToken: optional per-token callback for streaming the assistant reply into the
    ///   UI as it's generated (honoured by the Anthropic, OpenAI-compatible, and local providers).
    /// - Parameter onStreamReset: invoked at the start of each streamed tool-loop iteration so the
    ///   caller can clear its accumulated bubble — intermediate tool-turn text must never
    ///   concatenate with the final reply (BM P9).
    private var fieldConversationSourceID: String? {
        // The job's service is told which turn is in flight, so a team learning filed during it
        // withholds exactly this turn from the model's view of the job (Plan FP P1).
        didSet { FieldSessionService.shared.turnSourceID = fieldConversationSourceID }
    }

    func sendMessage(_ text: String, locationContext: String? = nil, imageData: Data? = nil, memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        // A scheduled run going on its own timer stops for this turn (`sendOffConversation`).
        await yieldOffConversationRun()
        // Capture the choice before prompt preparation can suspend and the picker can change.
        guard let requestedModel = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured — add one in Settings")
        }
        let previousFieldSourceID = fieldConversationSourceID
        fieldConversationSourceID = previousFieldSourceID ?? UUID().uuidString
        defer { fieldConversationSourceID = previousFieldSourceID }
        // Plan KL P1: what this attempt sends, for a per-minute refusal to be learned from.
        lastAttemptModel = nil
        lastAttemptFittable = false
        lastAttemptCarriedTools = true
        lastChatRequestShape = nil
        replyFollowUps = []
        replyWebSources = []
        replySearchSuggestions = nil
        // Plan KL P2: a turn the chain does not own starts its own ledger.
        if !cascadeTurnInFlight {
            turnToolLedger.reset()
            carryForwardFromHop = false
        }
        isProcessing = true
        beginTurnScope()
        defer {
            isProcessing = false
            endTurnScope()
            // A "new topic" requested DURING this turn (the model called the new_topic tool)
            // applies now that the turn is complete — clearing mid-loop would orphan the
            // pending tool_result and 400 the next request.
            if pendingHistoryClear {
                pendingHistoryClear = false
                clearHistory()
                PrivacyLog.model(.historyCleared, detail: PrivacyToken("deferredNewTopic"))
            }
        }

        // A scheduled task's prompt is not something the technician said.
        if !OffConversationScope.isActive {
            FieldSessionService.shared.recordConversationTurn(text, sourceID: fieldConversationSourceID ?? UUID().uuidString)
        }
        // ChatGPT selects a bounded request copy at every submission. Never run the legacy
        // history-only compactor first: it can erase evidence before the full budget is known.
        // Plan KK P2: the Agent Mode LLM summariser that used to run here is retired; earlier
        // messages are written up by the conversation timeline instead, after the reply.
        if Config.activeModel?.llmProvider != .chatgpt {
            compressContextWindowIfNeeded()
        }

        // Plan GB P5: a job that became active since the last turn starts the request history here.
        let turnStartIndex = conversationHistory.count
        let turnStartedAt = Date()
        jobHistoryFloor.turnStarted(at: turnStartIndex, sessionId: FieldSessionService.shared.activeSession?.id,
                                    now: turnStartedAt)
        // Plan KK P2: this turn's cloud request, if it builds one, says what it carried.
        lastTimelineReading = nil
        defer {
            // …and a job this turn started (a spoken "start a job") starts with this turn.
            jobHistoryFloor.turnFinished(startedAt: min(turnStartIndex, conversationHistory.count),
                                         sessionId: FieldSessionService.shared.activeSession?.id,
                                         turnStartedAt: turnStartedAt)
        }

        var modelConfig = try medicalInferenceModel(requested: requestedModel)
        if imageData != nil, modelConfig.id != requestedModel.id {
            throw LLMError.invalidConfiguration("Local-only privacy settings prevent sending this photo to the selected model. Select an available on-device vision model and try again.")
        }

        // A Field Assist job turn on Apple's on-device model goes to a model that can hold the job
        // (`OnDeviceJobRoutePolicy`), unless the cascade has already routed it.
        var jobRouteNotice: String?
        if let pending = pendingJobRouteNotice, pending.configId == modelConfig.id {
            jobRouteNotice = pending.notice
        }
        // The turn's model is the active one while it runs, as in a cascade: what reads the setting
        // mid-turn (the vault's size bound, the support trace) then reads the model answering.
        var restoreActiveModelId: String?
        defer {
            if let restoreActiveModelId {
                Config.setActiveModelId(restoreActiveModelId)
                refreshActiveModel()
            }
        }
        if !onDeviceJobRouteSettled,
           let routed = routeOnDeviceJobTurn(modelConfig, turn: text, requiresVision: imageData != nil) {
            modelConfig = routed.config
            jobRouteNotice = routed.notice
            if Config.savedModels.contains(where: { $0.id == routed.config.id }) {
                restoreActiveModelId = Config.activeModelId
                Config.setActiveModelId(routed.config.id)
            }
        }

        // Plan GB P5: spend caps — warn at 80%, ask at 100%, fall back only when opted in.
        var spendCapNotice: String?
        switch spendCapOutcome(utterance: text, config: modelConfig) {
        case .proceed:
            break
        case .proceedWithNotice(let line):
            spendCapNotice = line
        case .answer(let line):
            return line
        case .confirmed(let window, let reply):
            Config.spendCapOverrideWindow = window.key(now: Date())
            PrivacyLog.model(.spendCap, detail: PrivacyToken("confirmed-\(window.rawValue)"))
            return reply
        case .useCheaperModel(let cheaper, let notice):
            guard imageData == nil else {
                throw LLMError.invalidConfiguration("The selected model's spending limit prevents this photo request. Review the limit or select another vision model and try again.")
            }
            modelConfig = try medicalInferenceModel(requested: cheaper)
            spendCapNotice = notice
        }

        // The ChatGPT backend refuses, on every turn, a model the account's catalog does not list.
        // This turn sends the catalog's default instead; the saved setting is left as it is.
        var modelNotice: String?
        if modelConfig.llmProvider == .chatgpt,
           let offered = ChatGPTModelAvailability.modelForTurn(modelConfig.model,
                                                               accountID: chatGPTAccount.accountID) {
            PrivacyLog.model(.modelSubstituted, provider: PrivacyToken(LLMProvider.chatgpt.rawValue),
                             model: PrivacyToken(offered), detail: PrivacyToken(modelConfig.model))
            if Self.announcedModelSubstitutions.insert(modelConfig.model).inserted {
                modelNotice = ChatGPTModelAvailability.substitutionNotice
            }
            modelConfig.model = offered
        }

        let provider = modelConfig.llmProvider
        lastAttemptModel = modelConfig
        // Plan CU P1: tag the turn with the model that is about to serve it, read here rather than
        // afterwards. `sendMessageCascading` restores the pre-turn active model in a `defer` before
        // it returns, so anything that asks once the turn is over names the model that didn't
        // answer. Tags are last-wins, so a cascade's final attempt is the one that sticks.
        TurnRecorder.noteBackend(.direct(provider), model: modelConfig.model)
        if imageData != nil { TurnRecorder.noteImageSent() }

        let isOnDevice = (provider == .local || provider == .appleOnDevice)
        let hasNativeTools = nativeToolRouter != nil
        // A vault-only job does not reach the gateway (Plan KE), so the prompt does not offer it.
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil && !VaultOnlyPolicy.jobIsSealed
        let includeTools = hasNativeTools || includeOpenClaw
        // Plan GD3: the field-mode profile narrows the prompt's list exactly as it narrows the
        // declared schemas, so a tool is listed only when it is declared. Used by the agent-plan
        // block too, which then plans over the same names.
        let allNativeToolNames = nativeToolRouter?.registry.toolNames ?? []
        let nativeToolNames = FieldToolProfile.current(allNativeToolNames)
        if nativeToolNames.count < allNativeToolNames.count {
            PrivacyLog.model(.toolProfileApplied, count: nativeToolNames.count,
                             total: allNativeToolNames.count,
                             detail: PrivacyToken(FieldToolProfile.digest(nativeToolNames)))
        }

        // On-device models get a LEAN prompt regardless of how they were reached (active model or
        // agent). The full ~100-tool prompt is ~8k tokens and OOM-kills a 2B model on a phone;
        // `sendLocal` appends its own reduced tool block, so the model still has usable tools.
        // Cloud providers get the full tool-laden prompt. (`sendLocal` keeps `includeTools` so it
        // still adds the reduced set — only the PROMPT drops the ~100-tool dump.)
        // Vision honesty: a non-vision on-device model silently DROPS the image while the
        // vision prompt block insists "You CAN see images" — the model then invents a scene
        // (live-traced: described a cup that was never photographed). Refuse instead.
        // Demotion-aware when the service is in hand: a Gemma whose VLM load fell back to the
        // text factory would silently drop the image despite its architectural vision claim.
        if isOnDevice, imageData != nil,
           provider == .appleOnDevice
               || !(localLLMService?.isVisionUsable(modelId: modelConfig.model)
                    ?? LocalLLMService.isVisionCapable(modelId: modelConfig.model)) {
            // Don't recommend the very model being refused: a demoted Gemma is architecturally
            // vision-capable but this build's vision weights wouldn't load on this device.
            if provider != .appleOnDevice, LocalLLMService.isVisionCapable(modelId: modelConfig.model) {
                return LocalLLMService.visionWeightsUnavailableMessage
            }
            return "I can't look at photos with the current on-device model. Switch to a vision-capable local model like SmolVLM2, or a cloud model, and try again."
        }

        // The ChatGPT subscription integration cannot currently analyze images. Its photo
        // requests use another vision-capable provider through the cascade below.
        if case .declineVision(let message) = ChatGPTVisionGate.decide(provider: provider, hasImage: imageData != nil) {
            return message
        }
        if imageData != nil, !isOnDevice, !modelConfig.visionEnabled {
            throw LLMError.invalidConfiguration("The selected model has image input disabled. Enable Vision in its settings or select a vision model and try again.")
        }

        // Per-model: the lean prompt exists for tight providers (Groq's 8k cap) and would
        // strip tools from roomier ones. On-device is lean unconditionally, below.
        let smallContext = !isOnDevice && modelConfig.smallContextEnabled
        let effectiveIncludeTools = smallContext ? false : includeTools
        lastAttemptCarriedTools = effectiveIncludeTools

        var fullPrompt: String
        // Plan GB P5: on OpenAI and Anthropic the volatile tail travels separately, after the
        // history (OpenAI) or as an uncached second system block (Anthropic).
        var volatileTail: String?
        // Plan FY F3: the device this turn is on, read once here and passed to whichever prompt
        // tier answers.
        let device = Self.deviceInUse()
        // Plan IU: how much of the tool set this turn declares in full, decided once here — a turn
        // in flight keeps the mode it started with. Only where machine-readable schemas ride along.
        var exposureTurn: ToolExposureTurn?
        if provider == .appleOnDevice {
            fullPrompt = Self.appleOnDevicePrompt(locationContext: locationContext,
                                                  memoryContext: memoryContext, device: device)
        } else if isOnDevice {
            fullPrompt = await Self.leanOnDevicePrompt(
                locationContext: locationContext, memoryContext: memoryContext,
                hasImage: imageData != nil, turn: text, device: device)
        } else if smallContext {
            fullPrompt = Self.leanCloudPrompt(hasImage: imageData != nil, memoryContext: memoryContext,
                                              device: device)
        } else {
            // Plan GB P5: when the request carries machine-readable tool schemas, each tool's
            // description is already in them — sending it again in the prompt doubled ~8k tokens.
            let schemasAttached = Self.toolSchemasAttached(provider: provider,
                                                           customEndpointRejectsTools: Self.customEndpointRejectsTools)
            let nativeToolDescriptions = schemasAttached
                ? [] : (nativeToolRouter?.registry.toolDescriptions(for: nativeToolNames) ?? [])
            if schemasAttached && effectiveIncludeTools {
                exposureTurn = resolveToolExposure(config: modelConfig, includeOpenClaw: includeOpenClaw)
            }
            let onDemandGuide = exposureTurn.flatMap { onDemandToolGuide(for: $0.decision, nativeToolNames: nativeToolNames) }
            let gatewayToolNames = openClawBridge?.availableToolNames ?? []
            let layout = await Self.buildSystemPrompt(locationContext: locationContext, includeTools: includeTools, includeOpenClaw: includeOpenClaw, hasImage: imageData != nil, nativeToolNames: nativeToolNames, nativeToolDescriptions: nativeToolDescriptions, onDemandToolGuide: onDemandGuide, gatewayToolNames: gatewayToolNames, memoryContext: memoryContext, agentContext: agentContext, playbookContext: playbookContext, nowPlayingContext: nowPlayingContext, shortcutsContext: shortcutsContext, promptSections: promptSections, turn: text, offersFollowUps: true, device: device)
            if provider == .openai || provider == .anthropic {
                fullPrompt = layout.stable
                volatileTail = layout.volatile
            } else {
                fullPrompt = layout.combined
            }
        }

        if provider == .appleOnDevice, let manuals = PersonalManualLibrary.shared.promptContext {
            fullPrompt += "\n\n" + manuals
        }

        // Plan EK P2: the manual page a Field Assist turn pointed at goes into the turn's single
        // image slot when nothing else is using it. The figure was staged while the prompt above
        // was built (retrieval happens there), so the decision is made here, after it — and the
        // sentence announcing the page is appended only once the page has actually rendered, so
        // the prompt can never promise a picture the model did not get.
        var turnImage = imageData
        let stagedFigure = Config.fieldAssistActive ? FieldSessionService.shared.stagedFigure : PersonalManualLibrary.shared.takeStagedFigure()
        if let stagedFigure {
            let decision = ManualFigureAttachment.decide(
                staged: stagedFigure,
                sourceURL: FieldSessionService.shared.sourcePDFURL(for: stagedFigure),
                hasCameraImage: imageData != nil,
                isOnDevice: isOnDevice)
            if case .attach(let source, let page) = decision,
               let rendered = await ManualFigureAttachment.render(source: source, page: page),
               FieldSessionService.shared.sourcePDFURL(for: stagedFigure) == source {
                turnImage = rendered
                if let tail = volatileTail {
                    volatileTail = tail + "\n\n" + ManualFigureAttachment.promptLine(for: stagedFigure)
                } else {
                    fullPrompt += "\n\n" + ManualFigureAttachment.promptLine(for: stagedFigure)
                }
                if Config.fieldAssistActive { FieldSessionService.shared.logFigureSent(stagedFigure) }
            }
        }

        // The model *id* is a public catalog name; the configuration *name* is whatever the
        // wearer typed when they set it up, so it is fingerprinted rather than quoted.
        var capabilities: [String] = []
        if hasNativeTools && !smallContext { capabilities.append("nativeTools") }
        if includeOpenClaw && !smallContext { capabilities.append("openClaw") }
        if smallContext { capabilities.append("smallContext") }
        PrivacyLog.model(.turnStarted, provider: PrivacyToken(provider.rawValue),
                         model: PrivacyToken(modelConfig.model),
                         configuration: PrivateIdentifier(modelConfig.name),
                         detail: PrivacyToken(capabilities.joined(separator: "-")))

        // Plan-then-execute (Plan S): for a multi-step request in agent mode, plan deliberately and
        // run each step through the supervisor-gated router, instead of the single-shot tool loop.
        // The planner sees the request alone (not chat history), and tool output never re-enters
        // planning — the structural prompt-injection defense. Falls back to single-shot when the
        // request can't be planned/validated (still safe; every call is supervised either way).
        // Plan GE: not on a phone turn — the planner would reach for tools that need the network.
        if Config.agentModeEnabled, hasNativeTools, turnImage == nil, !offlineHandoffTurn,
           await classifyMultiStep(text) {
            if let summary = await runAgentPlan(request: text, nativeToolNames: nativeToolNames) {
                conversationHistory.append(["role": "user", "content": text])
                conversationHistory.append(["role": "assistant", "content": summary])
                trimHistory()
                return summary
            }
            PrivacyLog.model(.planLoopEmpty)
        }

        // Image hygiene for EVERY provider, not just Anthropic (where the request builder
        // already prunes): stale images re-upload with every turn, and on the Gemini /
        // OpenAI-compatible paths an unpruned photo history overflowed the context window
        // outright. Prune here so all providers start the turn with at most one prior image.
        // These are disposable in-memory model attachments, not ConversationStore's saved
        // photos. Keep their lifetime bounded even when text history is retained for FM.
        //
        // Plan GB P5: keep none. An image rides only on the turn that asked about it; the old
        // `keepLast: 1` re-sent the previous photo (~880 KB at the full size) on every request.
        conversationHistory = HistoryHygiene.pruneImages(conversationHistory, keepLast: 0)
        // Plan IE P2: and no thinking blocks from a finished, abandoned or other model's turn —
        // for every provider, since the history is shared and the next turn may be anyone's.
        conversationHistory = HistoryHygiene.stripThinkingBlocks(conversationHistory)

        // Plan KL P2: an attempt after a hop over read-only tools carries their results as already
        // fetched, in the turn's instructions — the uncached tail where there is one — so the
        // window budget and the per-minute fit below both count it.
        let carriedBlock = carriedToolBlock(onDevice: isOnDevice, provider: provider)
        if let carriedBlock {
            if let tail = volatileTail {
                volatileTail = tail + "\n\n" + carriedBlock
            } else {
                fullPrompt += "\n\n" + carriedBlock
            }
        }

        // Plan KL P1: a model whose account stated its tokens-a-minute allowance gets a request
        // fitted to it before it is sent — tools on demand, then the condensed instructions, then
        // a shorter history — or, when nothing fits, no request at all.
        var shortenedForAllowance = false
        if let exposure = exposureTurn, Self.perMinuteFitApplies(to: provider) {
            lastAttemptFittable = true
            if let allowance = perMinuteAllowances.allowance(for: modelConfig),
               let fitted = try fitToPerMinuteAllowance(
                   allowance, config: modelConfig, exposure: exposure, prompt: fullPrompt,
                   volatileTail: volatileTail, turn: text, includeOpenClaw: includeOpenClaw,
                   nativeToolNames: nativeToolNames, locationContext: locationContext,
                   memoryContext: memoryContext, hasImage: turnImage != nil, device: device,
                   carriedBlock: carriedBlock) {
                fullPrompt = fitted.prompt
                volatileTail = fitted.volatileTail
                exposureTurn = fitted.exposure
                shortenedForAllowance = fitted.shortened
            }
        }

        // Plan IU: the provider loops and the tool dispatcher read this turn's exposure from here.
        let promptForTurn = fullPrompt
        let tailForTurn = volatileTail
        // Plan KZ §5: the turn's web mark, set when a provider search's pages reach the model.
        let providerResponse: String = try await PerMinuteFitScope.$shortened.withValue(shortenedForAllowance) {
            try await TurnWebExposure.$current.withValue(TurnWebExposure()) {
            try await ToolExposureScope.$turn.withValue(exposureTurn) {
                switch provider {
                case .anthropic:
                    return try await sendAnthropic(text, systemPrompt: promptForTurn, volatileTail: tailForTurn, config: modelConfig, includeTools: effectiveIncludeTools, imageData: turnImage, smallContext: smallContext, onToken: onToken, onStreamReset: onStreamReset)
                case .chatgpt:
                    return try await sendChatGPT(text, systemPrompt: promptForTurn, config: modelConfig, includeTools: effectiveIncludeTools, imageData: turnImage, smallContext: smallContext, onToken: onToken, onStreamReset: onStreamReset)
                case .gemini, .geminiVertex:
                    return try await sendGemini(text, systemPrompt: promptForTurn, config: modelConfig, includeTools: effectiveIncludeTools, imageData: turnImage, smallContext: smallContext)
                case .local:
                    return try await sendLocal(text, systemPrompt: promptForTurn, config: modelConfig, includeTools: includeTools, imageData: turnImage, onToken: onToken)
                case .appleOnDevice:
                    return try await sendAppleOnDevice(text, systemPrompt: promptForTurn,
                                                       includeTools: hasNativeTools, carryHistory: true)
                case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                    return try await sendOpenAICompatible(text, systemPrompt: promptForTurn, volatileTail: tailForTurn, config: modelConfig, includeTools: effectiveIncludeTools, imageData: turnImage, smallContext: smallContext, onToken: onToken, onStreamReset: onStreamReset)
                }
            }
            }
        }
        // Plan KD P3: one chokepoint for every provider, before the reply is spoken, logged or
        // shown — a reply that repeats its own last part is said and kept once.
        // Plan KP P2: and its follow-up tail is taken off here, before the job's log, the
        // transcript, memory, speech or the HUD sees it, and out of the history the model is sent
        // on later turns.
        let rawResponse = takingFollowUpTail(collapsingRepeatedReply(providerResponse))

        // Local reasoning models (LFM2.5) are stripped at the generate layer —
        // LocalLLMService owns the template-opened <think> handling and every local
        // consumer needs the clean answer, not just this path. Surface the suppressed
        // chain-of-thought for the prompt inspector and return the (already clean) text.
        if provider == .local, let localThink = localLLMService?.lastReasoning {
            lastReasoning = localThink
            // An answer resting on a team learning alone opens with the fixed lead-in (Plan FP P2).
            let disclosed = FieldSessionService.shared.applyTeamLearningDisclosure(to: rawResponse)
            recordFieldAssistantReply(disclosed)
            return withJobRouteNotice(jobRouteNotice, disclosed)
        }

        let (stripped, reasoning) = Self.stripThinkTags(rawResponse)
        // An answer resting on a team learning alone opens with the fixed lead-in (Plan FP P2):
        // composed by the app, not left to the model's phrasing, and logged as it was spoken.
        let spoken = FieldSessionService.shared.applyTeamLearningDisclosure(to: stripped)
        lastReasoning = reasoning
        if let reasoning {
            // A reasoning trace is the model thinking about what the wearer just said — the same
            // class as the transcript itself. Its length is the useful part (a runaway thinking
            // pass is a length problem), and the only part kept.
            PrivacyLog.model(.reasoningProduced, characters: reasoning.count)
        }
        // The job's log keeps the model's reply, not the app's spend notice in front of it.
        recordFieldAssistantReply(spoken)
        let reply = ([modelNotice, spendCapNotice].compactMap { $0 } + [spoken]).joined(separator: " ")
        return withJobRouteNotice(jobRouteNotice, reply)
    }

    // MARK: - Field Assist jobs off the on-device model

    /// The configuration a job turn on Apple's on-device model is handed to, with the sentence to
    /// say first (once per process), or nil when the turn stays where it is. Logs the decision.
    private func routeOnDeviceJobTurn(_ config: ModelConfig, turn: String,
                                      requiresVision: Bool) -> (config: ModelConfig, notice: String?)? {
        let route = onDeviceJobRoute(for: config, turn: turn, requiresVision: requiresVision)
        logOnDeviceJobRoute(route)
        guard case .handOff(let to, let announce) = route,
              let target = Config.savedModels.first(where: { $0.id == to.id }),
              let resolved = try? medicalInferenceModel(requested: target),
              resolved.llmProvider != .appleOnDevice else { return nil }
        return (resolved, announce ? OnDeviceJobRoutePolicy.notice(modelName: to.name) : nil)
    }

    /// The policy's decision for `config` and this turn.
    private func onDeviceJobRoute(for config: ModelConfig, turn: String,
                                  requiresVision: Bool) -> OnDeviceJobRoutePolicy.Route {
        guard config.llmProvider == .appleOnDevice else { return .unchanged }
        let localOnly = MedicalLLMRoutingPolicy.isEnforced(
            hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly)
        let alternatives = OnDeviceJobRoutePolicy.orderedAlternatives(
            activeId: config.id, saved: Config.savedModels, fallbackOrder: Config.modelFallbackOrder,
            isUsable: { candidate in
                canServeJobTurn(candidate, localOnly: localOnly)
                    && (!requiresVision || ModelFallbackChain.candidate(from: candidate).supportsVision)
            })
        return OnDeviceJobRoutePolicy.decide(.init(
            jobOpen: FieldToolProfile.fieldJobActive,
            jobTurn: Config.fieldAssistActive && ManualTurnScope.isJobManagement(turn),
            activeProvider: config.llmProvider,
            alternatives: alternatives,
            offlineHandoff: offlineHandoffTurn,
            announcedThisProcess: Self.onDeviceJobRouteAnnounced))
    }

    /// Whether a saved configuration can take a job turn now: a downloaded local model, or a cloud
    /// model with its key (or its account route) while the medical local-only rule is off.
    private func canServeJobTurn(_ config: ModelConfig, localOnly: Bool) -> Bool {
        switch config.llmProvider {
        case .appleOnDevice:
            return false
        case .local:
            return localLLMService?.isModelDownloaded(config.model) ?? false
        case .chatgpt, .geminiVertex:
            // Account sign-in; a route that is signed out fails its first request and the cascade
            // moves on, as it would for the active model.
            return !localOnly
        case .anthropic:
            return !localOnly && (!config.apiKey.isEmpty || claudeAccount.isConnected)
        case .xai:
            return !localOnly && (!config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || xaiAccount.isConnected)
        case .custom:
            return !localOnly && !config.baseURL.isEmpty
        default:
            return !localOnly && !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func logOnDeviceJobRoute(_ route: OnDeviceJobRoutePolicy.Route) {
        switch route {
        case .unchanged:
            break
        case .handOff(let to, let announce):
            PrivacyLog.model(.onDeviceJobRouted, provider: PrivacyToken(to.provider.rawValue),
                             model: PrivacyToken(to.model), configuration: PrivateIdentifier(to.name),
                             success: announce, detail: PrivacyToken("handOff"))
        case .stayOnDevice(let reason):
            PrivacyLog.model(.onDeviceJobRouted, provider: PrivacyToken(LLMProvider.appleOnDevice.rawValue),
                             detail: PrivacyToken("stayOnDevice"), reason: PrivacyToken(reason.rawValue))
        }
    }

    /// The reply with the hand-off sentence in front, the first time it is owed in a process.
    private func withJobRouteNotice(_ notice: String?, _ reply: String) -> String {
        guard let notice else { return reply }
        Self.onDeviceJobRouteAnnounced = true
        pendingJobRouteNotice = nil
        return notice + " " + reply
    }

    // MARK: - Spend caps (Plan GB P5)

    private var spendCapGate = SpendCapGate()

    /// Evaluate the caps for a turn about to go to `config`. Priced spend comes from the local
    /// usage store; nothing here leaves the device.
    private func spendCapOutcome(utterance: String, config: ModelConfig) -> SpendCapGate.Outcome {
        let caps = SpendCapPolicy.Caps(dailyUSD: Config.dailySpendCapUSD,
                                       monthlyUSD: Config.monthlySpendCapUSD,
                                       fallBackToCheaperModel: Config.spendCapFallbackToCheaperModel)
        guard !caps.isEmpty else { return .proceed }
        let now = Date()
        let spent = UsageTracker.shared.spend(now: now)
        let decision = SpendCapPolicy.decide(spentToday: spent.today, spentMonth: spent.month, caps: caps,
                                             pricing: Self.spendPricing(config),
                                             overrideKey: Config.spendCapOverrideWindow, now: now)
        let outcome = spendCapGate.evaluate(decision, utterance: utterance, now: now) {
            SpendCapPolicy.cheaperModel(than: config, among: Config.savedModels)
        }
        if outcome != .proceed {
            PrivacyLog.model(.spendCap, detail: PrivacyToken(PrivacyToken.caseName(of: decision)?.description ?? "decision"))
        }
        return outcome
    }

    /// How a model's usage is billed, for the spend cap.
    static func spendPricing(_ config: ModelConfig) -> SpendCapPolicy.Pricing {
        switch config.llmProvider {
        case .local, .appleOnDevice, .chatgpt: return .free
        default: return ModelPricing.rate(for: config.model) == nil ? .unpriced : .priced
        }
    }

    /// The provider's reply with a repeated end said once (Plan KD P3), and the history entry the
    /// provider path appended for it made to match, so the next turn's model sees what was said.
    private func collapsingRepeatedReply(_ reply: String) -> String {
        let collapsed = RepeatedReplyCollapse.collapse(reply)
        guard collapsed != reply else { return reply }
        conversationHistory = RepeatedReplyCollapse.replacingLastAssistantReply(
            in: conversationHistory, original: reply, with: collapsed)
        PrivacyLog.model(.replyRepeatCollapsed, characters: reply.count - collapsed.count)
        return collapsed
    }

    /// Plan KP P2: take the follow-up tail off a reply (`FollowUpTail.parse`) and off the history
    /// entry that recorded it, keep its questions in `replyFollowUps`, and return the answer. A
    /// reply without a tail, or with a malformed one, is returned as `FollowUpTail` leaves it.
    func takingFollowUpTail(_ reply: String) -> String {
        let tail = FollowUpTail.parse(reply)
        replyFollowUps = tail.followUps
        guard tail.removedTail else { return reply }
        conversationHistory = Self.removingFollowUpTailFromLastAssistant(conversationHistory)
        return tail.answer
    }

    /// The history with the tail taken off its last assistant message: plain text, or the text
    /// of its last text part (Gemini's `parts`, Anthropic's content blocks). The model never sees
    /// its own tags again, and a restored or exported history carries none. Pure.
    static func removingFollowUpTailFromLastAssistant(_ history: [[String: Any]]) -> [[String: Any]] {
        guard let index = history.lastIndex(where: { $0["role"] as? String == "assistant" }) else {
            return history
        }
        var history = history
        var message = history[index]
        if let content = message["content"] as? String {
            message["content"] = FollowUpTail.parse(content).answer
        } else {
            for key in ["content", "parts"] {
                guard var blocks = message[key] as? [[String: Any]],
                      let last = blocks.lastIndex(where: { $0["text"] is String }),
                      let text = blocks[last]["text"] as? String else { continue }
                blocks[last]["text"] = FollowUpTail.parse(text).answer
                message[key] = blocks
            }
        }
        history[index] = message
        return history
    }

    /// The final reply joins the job's log beside the turn that asked for it (Plan GB P0), so a
    /// job's transcript has both sides. Direct mode only; no-op with no job open.
    private func recordFieldAssistantReply(_ reply: String) {
        FieldSessionService.shared.recordAssistantReply(
            reply, sourceID: fieldConversationSourceID ?? UUID().uuidString)
    }

    // MARK: - Offline handoff (Plan GE)

    /// Set by `AppState` for a turn the offline handoff routed to the phone: no cloud hops, the
    /// offline tool set, and the history window `HandoffTranscriptBridge` picks for the on-device
    /// budget. Cleared when the turn finishes.
    var offlineHandoffTurn = false

    /// The outcome of every cloud model attempt (nil on success), for the offline handoff.
    var onCloudAttempt: ((Error?) -> Void)?

    nonisolated static func isOnDeviceProvider(_ provider: LLMProvider) -> Bool {
        provider == .local || provider == .appleOnDevice
    }

    /// The on-device tool names for a turn: the reduced local set, narrowed further to what works
    /// without signal when the handoff put the turn on the phone. Pure.
    nonisolated static func localToolNames(registered: [String], offlineHandoff: Bool,
                                          libraryHasManuals: Bool = false) -> [String] {
        let manualTools: Set<String> = libraryHasManuals ? ["manual_lookup", "table_lookup", "manual_figure", "show_source"] : []
        let local = registered.filter { localSafeTools.contains($0) || manualTools.contains($0) }
        return offlineHandoff ? OfflineToolPolicy.offlineNames(local) : local
    }

    // MARK: - Per-minute allowance (Plan KL P1)

    /// Where learned allowances are kept. A seam for tests; the app uses the shared store.
    var perMinuteAllowances: PerMinuteAllowanceStore = .shared

    /// Tool calls dispatched in this process, by every provider's loop and the on-device one. A
    /// retry compares it before and after an attempt: an attempt that moved it has run something,
    /// and is never sent again.
    private(set) var toolCallsDispatched = 0

    // MARK: - A hop keeps the work (Plan KL P2)

    /// Every model tool call of the turn, across its attempts, with what its tool declares it does
    /// (`HopAfterTools`). Reset when a turn starts; tool names, arguments and results stay in memory
    /// for the next attempt's request and are never logged.
    private(set) var turnToolLedger = AttemptToolLedger()
    /// Set when the chain hopped after read-only tools: the next attempt's request carries their
    /// results as already fetched.
    private var carryForwardFromHop = false
    /// Whether `sendMessageCascading` owns the ledger for the turn in flight. A `sendMessage`
    /// called on its own starts a fresh one.
    private var cascadeTurnInFlight = false

    /// A tool's declared effect: its native declaration, or — for an MCP server's tool, the
    /// gateway, a name the registry does not hold — the conservative default, which counts as a
    /// change.
    private func declaredEffect(ofTool name: String) -> ToolEffect {
        (nativeToolRouter?.registry.tool(named: name)?.executionSemantics
            ?? ToolExecutionSemantics.conservativeDefault).effect
    }

    /// The effect a call is entered with: read-only when it is one of the read actions of a native
    /// tool declared by its writing action (`ToolEffectClassifier.isReadAction` — a calendar
    /// "today", a reminders "list"), otherwise its tool's declared effect.
    private func callEffect(ofTool name: String, args: [String: Any]) -> ToolEffect {
        if nativeToolRouter?.registry.tool(named: name) != nil,
           ToolEffectClassifier.isReadAction(tool: name, args: args) {
            return .readOnly
        }
        return declaredEffect(ofTool: name)
    }

    /// Enter a model tool call in the turn's ledger as it is dispatched; returns its id.
    private func ledgerDispatched(_ name: String, args: [String: Any], arguments: String? = nil) -> Int {
        turnToolLedger.dispatched(tool: name, arguments: arguments ?? AttemptToolLedger.canonicalArguments(args),
                                  effect: callEffect(ofTool: name, args: args),
                                  isNative: nativeToolRouter?.registry.tool(named: name) != nil)
    }

    /// The decision for a hop the chain is about to make (Plan KL P2). Returns normally to hop —
    /// marking the next attempt to carry read-only results when there are any — and throws to end
    /// the turn instead: the overflow's own error after any tool, as before, or `TurnEnded` when a
    /// tool that may have changed something has run.
    private func decideHopAfterTools(after error: Error) throws {
        let ledger = turnToolLedger
        let overflow = HopAfterTools.isOverflow(error)
        let decision = HopAfterTools.decide(toolsRan: ledger.toolsRan, overflow: overflow)
        guard decision != .restart else {
            carryForwardFromHop = false
            return
        }
        PrivacyLog.model(.hopAfterTools, count: ledger.ran.count, detail: PrivacyToken(decision.rawValue),
                         reason: PrivacyToken(ledger.toolsRan.rawValue), error: SafeErrorSummary(error))
        let registry = nativeToolRouter?.registry
        for ran in ledger.ranTools {
            PrivacyLog.model(.hopToolRan,
                             detail: PrivacyToken(registry?.tool(named: ran.tool) != nil ? ran.tool : "other"),
                             reason: PrivacyToken(ran.effect.rawValue))
        }
        switch decision {
        case .restart:
            carryForwardFromHop = false
        case .carryForward:
            carryForwardFromHop = true
        case .endTurn:
            carryForwardFromHop = false
            if overflow { throw error }
            throw HopAfterTools.TurnEnded(
                tools: ledger.changingTools.map {
                    HopAfterTools.spokenToolName($0, isNative: registry?.tool(named: $0) != nil)
                },
                underlying: SafeErrorSummary(error))
        }
    }

    /// The already-fetched block a carried attempt sends, bounded for the model it goes to, and
    /// logged by its counts. Nil when the attempt is not carrying.
    private func carriedToolBlock(onDevice: Bool, provider: LLMProvider) -> String? {
        guard carryForwardFromHop,
              let block = turnToolLedger.carriedBlock(
                limit: onDevice ? HopAfterTools.onDeviceBlockLimit : HopAfterTools.cloudBlockLimit,
                excluding: [ToolLookupTool.toolName],
                wrap: { self.wrapToolResultForModel(toolName: $0, content: $1) })
        else { return nil }
        PrivacyLog.model(.hopAfterTools, provider: PrivacyToken(provider.rawValue), count: block.carried,
                         total: block.omitted, characters: block.text.count,
                         detail: PrivacyToken("carriedBlock"), reason: block.cut > 0 ? PrivacyToken("cut") : nil)
        return block.text
    }

    /// The hop's log line: where it went, the class, and the error it was from (Plan KL P2).
    @discardableResult
    nonisolated static func logCascadeSwitch(to configurationID: String,
                                             failure: ModelFallbackChain.FailureClass,
                                             error: Error?) -> PrivacyEvent {
        PrivacyLog.model(.cascadeSwitched, configuration: PrivateIdentifier(configurationID),
                         detail: PrivacyToken.caseName(of: failure),
                         error: error.map { SafeErrorSummary($0) })
    }

    /// The configuration the last attempt was sent to, as resolved for the turn (a spend cap's
    /// cheaper model, a job route's model), and whether its request could be fitted: it carried
    /// tool schemas on demand-capable exposure, on a provider the fit serves.
    private var lastAttemptModel: ModelConfig?
    private var lastAttemptFittable = false
    /// Whether the last attempt's request carried tools, for the line said about it.
    private var lastAttemptCarriedTools = true
    /// The last Chat Completions request's body size and output cap, as sent: the app's estimate
    /// of a refused request, which a refusal's own count calibrates.
    private var lastChatRequestShape: (bodyBytes: Int, outputCap: Int)?
    /// What the last failed attempt of the turn said about the allowance, with the error it was
    /// read from — matched as `lastAttemptCredentialGap` is.
    private var lastAttemptPerMinute: (notice: PerMinuteNotice, error: String)?

    /// The providers whose requests the fit can reshape: the OpenAI-compatible family, sent to Chat
    /// Completions, where Groq's per-minute refusal comes from. OpenAI's own API answers a
    /// per-minute limit with a 429 instead, and the other providers build their requests apart.
    nonisolated static func perMinuteFitApplies(to provider: LLMProvider) -> Bool {
        switch provider {
        case .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom: return true
        case .openai, .anthropic, .chatgpt, .gemini, .geminiVertex, .local, .appleOnDevice: return false
        }
    }

    /// What the turn knows about a refusal over the per-minute allowance behind `error`, when it is
    /// the last attempt's failure: the service, the allowance, and whether the request carried
    /// tools — the one thing the error itself cannot say.
    func perMinuteNotice(behind error: Error) -> PerMinuteNotice? {
        if let last = lastAttemptPerMinute, last.error == String(reflecting: error) { return last.notice }
        return PerMinuteNotice.from(error)
    }

    /// Record what a failed attempt says about its model's allowance. True when it was a refusal
    /// with figures that a fitted request can answer — the retry's condition.
    private func learnPerMinuteAllowance(from error: Error) -> Bool {
        guard case LLMError.apiError(_, _, _, let rejection?) = error,
              rejection.reason == .requestOverTokenRateLimit, let limit = rejection.limit,
              let model = lastAttemptModel else { return false }
        let estimate = lastChatRequestShape.map {
            PerMinuteFit.estimatedTokens(bodyBytes: $0.bodyBytes, outputCap: $0.outputCap)
        }
        let learned = perMinuteAllowances.record(limit: limit, requested: rejection.requested,
                                                 estimate: estimate, for: model)
        PrivacyLog.model(.perMinuteFit, provider: PrivacyToken(model.llmProvider.rawValue),
                         model: PrivacyToken(model.model), tokens: estimate,
                         detail: PrivacyToken("learned"),
                         reason: PrivacyToken(learned.calibration == nil ? "uncalibrated" : "calibrated"),
                         limit: limit, requested: rejection.requested)
        return lastAttemptFittable
    }

    /// The Chat Completions output cap of a tool turn on `config`, as `sendOpenAICompatible`
    /// computes it: the tool turn's ceiling, raised for a model that reasons.
    private static func chatToolTurnOutputCap(_ config: ModelConfig) -> Int {
        let reasoning = config.routeSelection(
            toolsAttached: true,
            learnedToolRejection: reasoningToolRejections.contains(config.model),
            learnedResponsesRejection: responsesRouteRejections.contains(config.model)).reasoning
        return reasoning.outputCap(base: toolTurnMaxTokens)
    }

    /// The request a turn on `config` sends, fitted to `allowance` (Plan KL P1). Nil when the
    /// request fits as it is; throws `PerMinuteFit.NothingFits` when no rung does.
    ///
    /// Each rung is measured as the request builder would send it: the prompt's bytes, the tool
    /// definitions it declares serialized, the history it carries and its output cap. The history
    /// is this turn's: the conversation so far, the turn's own message after it.
    private func fitToPerMinuteAllowance(
        _ allowance: PerMinuteAllowance, config: ModelConfig, exposure: ToolExposureTurn,
        prompt: String, volatileTail: String?, turn: String, includeOpenClaw: Bool,
        nativeToolNames: [String], locationContext: String?, memoryContext: String?,
        hasImage: Bool, device: AssistantIdentity.Device, carriedBlock: String? = nil
    ) throws -> (prompt: String, volatileTail: String?, exposure: ToolExposureTurn, shortened: Bool)? {
        let provider = config.llmProvider
        let registry = nativeToolRouter?.registry
        let mcpClient = nativeToolRouter?.mcpClient
        func bytes(_ object: Any) -> Int {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))?.count ?? 0
        }
        func toolBytes(_ decision: ToolExposureDecision) -> Int {
            bytes(ToolDeclarations.openAITools(
                registry: registry, includeOpenClaw: includeOpenClaw, mcpClient: mcpClient,
                declaring: ToolExposurePolicy.roundDeclared(decision, promoted: toolExposureMemory)))
        }
        let pending = conversationHistory + [["role": "user", "content": turn]]
        // `requestHistory`'s own rule: Groq's request carries the last six messages.
        let sentHistory = provider == .groq ? Array(pending.suffix(6)) : pending
        let shortHistory = PerMinuteFit.shortHistory(pending, turnStart: conversationHistory.count)
        let outputCap = Self.chatToolTurnOutputCap(config)
        let tailBytes = volatileTail?.utf8.count ?? 0

        let asSent = PerMinuteFit.Request(instructionBytes: prompt.utf8.count + tailBytes,
                                          toolBytes: toolBytes(exposure.decision),
                                          historyBytes: bytes(sentHistory), outputCap: outputCap)
        var ladder = PerMinuteFit.Ladder(asSent: asSent)

        // Rungs 2–4 put every tool one lookup away, which needs the lookup tool and an exposure the
        // organisation has not pinned to every definition.
        let emptied = ToolExposurePolicy.emptyingCore(exposure.decision, remembered: toolExposureMemory)
        let onDemandPossible = Config.toolDefinitionsMode != .never
            && registry?.tool(named: ToolLookupTool.toolName) != nil
        var onDemandPrompt: String?
        var condensed: (text: String, blocks: [TurnTimeline.PromptBlock])?
        if onDemandPossible,
           let guide = onDemandToolGuide(for: emptied, nativeToolNames: nativeToolNames, core: []) {
            // The guide the prompt already carries is replaced; a prompt on full exposure had none.
            if let current = onDemandToolGuide(for: exposure.decision, nativeToolNames: nativeToolNames),
               prompt.contains(current) {
                onDemandPrompt = prompt.replacingOccurrences(of: current, with: guide)
            } else {
                onDemandPrompt = prompt + "\n\n" + guide
            }
            var condensedPrompt = Self.condensedCloudPrompt(locationContext: locationContext,
                                                            memoryContext: memoryContext, hasImage: hasImage,
                                                            toolGuide: guide, device: device)
            // Plan KL P2: the condensed instructions replace the prompt the carried block was
            // added to, so they carry it too.
            if let carriedBlock { condensedPrompt.text += "\n\n" + carriedBlock }
            condensed = condensedPrompt
            let emptiedTools = toolBytes(emptied)
            ladder.onDemandTools = .init(instructionBytes: (onDemandPrompt?.utf8.count ?? 0) + tailBytes,
                                         toolBytes: emptiedTools, historyBytes: asSent.historyBytes,
                                         outputCap: outputCap)
            ladder.condensedInstructions = .init(instructionBytes: condensedPrompt.text.utf8.count,
                                                 toolBytes: emptiedTools, historyBytes: asSent.historyBytes,
                                                 outputCap: outputCap)
            ladder.shortHistory = .init(instructionBytes: condensedPrompt.text.utf8.count,
                                        toolBytes: emptiedTools, historyBytes: bytes(shortHistory),
                                        outputCap: PerMinuteFit.shortenedOutputCap(outputCap))
        }

        let choice = PerMinuteFit.choose(ladder, allowance: allowance)
        PrivacyLog.model(.perMinuteFit, provider: PrivacyToken(provider.rawValue),
                         model: PrivacyToken(config.model), total: choice.ceiling,
                         tokens: choice.estimate, detail: PrivacyToken(choice.rung.rawValue),
                         limit: allowance.limit)
        func onDemand() -> ToolExposureTurn {
            PrivacyLog.model(.toolExposure, provider: PrivacyToken(provider.rawValue),
                             model: PrivacyToken(config.model),
                             count: emptied.declared.count + 1 + (includeOpenClaw ? 1 : 0),
                             total: emptied.available.count + (includeOpenClaw ? 1 : 0),
                             tokens: emptied.fullSetTokens, detail: PrivacyToken(emptied.exposure.rawValue),
                             reason: PrivacyToken(emptied.reason.rawValue))
            return ToolExposureTurn(decision: emptied)
        }
        switch choice.rung {
        case .asSent:
            return nil
        case .onDemandTools:
            return (onDemandPrompt ?? prompt, volatileTail, onDemand(), false)
        case .condensedInstructions, .shortHistory:
            guard let condensed else { return nil }
            TurnRecorder.notePromptBlocks(condensed.blocks)
            return (condensed.text, nil, onDemand(), choice.rung == .shortHistory)
        case .nothingFits:
            throw PerMinuteFit.NothingFits(provider: provider, limit: allowance.limit, needed: choice.estimate)
        }
    }

    // MARK: - Model Cascade (BK P2b)

    /// The credential gap behind the last failed attempt of the current turn, with the error it
    /// was read from (Plan KL P0). Held in memory only, and only to be matched below.
    private var lastAttemptCredentialGap: (gap: CredentialGap, error: String)?

    /// The credential gap of the model that threw `error`, when `error` is the last attempt's
    /// failure — so a turn that ran out of models names the service whose sign-in or key failed.
    /// Matched on the error itself, so a failure from anywhere else is never blamed on a sign-in.
    func credentialGap(behind error: Error) -> CredentialGap? {
        guard let last = lastAttemptCredentialGap, last.error == String(reflecting: error) else { return nil }
        return last.gap
    }

    /// `sendMessage` with automatic fall-over to the next model when the active one can't serve the
    /// turn (`promptTooLong`, `429`/quota, empty completion, …). The active model leads; the user's
    /// fallback order (then the remaining saved models) follow. Between hops the active model is
    /// swapped and the conversation history is rewound to its pre-turn snapshot so a failed attempt
    /// never leaves half a turn (or a duplicated user turn) behind. The active model is always
    /// restored on exit, so a cascade is transparent to the caller's own switch/restore bookkeeping.
    ///
    /// Falls straight through to a single `sendMessage` when the cascade is disabled or there's only
    /// one candidate. Exhaustion throws the *last real* error (not a generic line) so the caller can
    /// speak the true reason.
    func sendMessageCascading(_ text: String, locationContext: String? = nil, imageData: Data? = nil, memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, backgrounded: Bool = false, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil, onModelSwitch: ((_ from: ModelConfig?, _ to: ModelConfig?, _ failure: ModelFallbackChain.FailureClass, _ error: Error?) async -> Void)? = nil) async throws -> String {
        // Before the chain takes its history snapshot below.
        await yieldOffConversationRun()

        let previousSourceID = fieldConversationSourceID
        // Plan KL P0: a gap belongs to the turn that recorded it.
        lastAttemptCredentialGap = nil
        lastAttemptPerMinute = nil
        // Plan KL P2: the turn's ledger starts empty and is kept across its attempts.
        turnToolLedger.reset()
        carryForwardFromHop = false
        cascadeTurnInFlight = true
        defer {
            cascadeTurnInFlight = false
            carryForwardFromHop = false
        }
        fieldConversationSourceID = UUID().uuidString
        defer { fieldConversationSourceID = previousSourceID }

        func send() async throws -> String {
            // Plan GE: every cloud attempt tells the offline handoff how the network is doing — a
            // connectivity-class failure counts toward moving the conversation onto the phone.
            let isCloud = Config.activeModel.map { !Self.isOnDeviceProvider($0.llmProvider) } ?? false
            // Plan KL P1: a refusal over the account's per-minute allowance with its figures is
            // answered on this same model, once, with a request fitted to them — before the chain
            // hops. The refusal comes before the model does anything; the dispatch count makes sure
            // of it, and an attempt that ran a tool is never sent again.
            let historyBeforeAttempt = conversationHistory
            let toolCallsBeforeAttempt = toolCallsDispatched
            do {
                let response = try await PerMinuteRetry.run(
                    attempt: {
                        try await sendMessage(text, locationContext: locationContext, imageData: imageData, memoryContext: memoryContext, agentContext: agentContext, playbookContext: playbookContext, nowPlayingContext: nowPlayingContext, shortcutsContext: shortcutsContext, promptSections: promptSections, onToken: onToken, onStreamReset: onStreamReset)
                    },
                    learn: { self.learnPerMinuteAllowance(from: $0) },
                    toolRan: { self.toolCallsDispatched != toolCallsBeforeAttempt },
                    beforeRetry: {
                        self.conversationHistory = historyBeforeAttempt
                        onStreamReset?()
                        PrivacyLog.model(.perMinuteRetry,
                                         provider: self.lastAttemptModel.map { PrivacyToken($0.llmProvider.rawValue) },
                                         model: self.lastAttemptModel.map { PrivacyToken($0.model) })
                    })
                if isCloud { onCloudAttempt?(nil) }
                return response
            } catch {
                // Plan KL P0: which model's sign-in or key failed, for the turn's spoken reason.
                lastAttemptCredentialGap = CredentialGap.classify(error, model: Config.activeModel)
                    .map { ($0, String(reflecting: error)) }
                // Plan KL P1: and what a per-minute refusal can't say itself — the service, and
                // whether the request carried tools.
                lastAttemptPerMinute = PerMinuteNotice.from(error, provider: lastAttemptModel?.llmProvider,
                                                            carriedTools: lastAttemptCarriedTools)
                    .map { ($0, String(reflecting: error)) }
                // A failed attempt that ran no tool leaves the history as it found it, so a turn
                // with no answer never leaves an unanswered message for the next one to read. One
                // that ran a tool keeps it: what the tool did stays on the record.
                if toolCallsDispatched == toolCallsBeforeAttempt {
                    conversationHistory = historyBeforeAttempt
                }
                // A request given up on says nothing about the network, either way.
                if LLMError.isSlowResponse(error) {
                    PrivacyLog.model(.firstReplyGaveUp, error: SafeErrorSummary(error))
                } else if isCloud {
                    onCloudAttempt?(error)
                }
                throw error
            }
        }

        // The normal cascade intentionally contains cloud models. Under medical local-only policy,
        // one resolved local attempt is authoritative: a local failure must surface, never hop to
        // an otherwise eligible cloud candidate.
        if MedicalLLMRoutingPolicy.isEnforced(
            hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) {
            return try await send()
        }

        // Plan GE: the handoff put this turn on the phone. Hopping to a cloud candidate would only
        // wait out the same timeout the handoff exists to skip, so the on-device attempt is the turn.
        if offlineHandoffTurn {
            return try await send()
        }

        // A job turn on Apple's on-device model starts the cascade on the model it is handed to,
        // so a failure there moves on through the chain instead of being routed again.
        var leadId = Config.activeModelId
        var routedNotice: (configId: String, notice: String)?
        var routeEvaluated = false
        if Config.modelCascadeEnabled || imageData != nil, let active = Config.activeModel,
           active.llmProvider == .appleOnDevice {
            routeEvaluated = true
            if let routed = routeOnDeviceJobTurn(active, turn: text, requiresVision: imageData != nil),
               Config.savedModels.contains(where: { $0.id == routed.config.id }) {
                leadId = routed.config.id
                routedNotice = routed.notice.map { (routed.config.id, $0) }
            }
        }

        // Plan KA P1: a photo turn tries the chosen Vision model first; the rest of the
        // conversation stays on the assistant.
        let visionModelId = imageData != nil ? Config.visionRoleModelId : nil
        let chain = ModelFallbackChain.candidates(
            activeId: leadId, saved: Config.savedModels,
            fallbackOrder: Config.modelFallbackOrder, requiresVision: imageData != nil,
            visionModelId: visionModelId)
        // A photo needs a capable model even when the text-request fallback switch is off.
        guard (Config.modelCascadeEnabled || imageData != nil), !chain.isEmpty else {
            return try await send()
        }
        // A lead the last turn hopped away from stays second for a while: the model that
        // answered starts, so the wearer does not wait out the same failure every turn.
        let now = Date()
        // The memory's hold is about the assistant's lead; a chosen Vision model keeps the front.
        let candidates = visionModelId != nil && chain.first?.id == visionModelId
            ? chain : cascadeMemory.ordered(chain, lead: leadId, now: now)
        if let first = candidates.first, first.id != chain.first?.id {
            PrivacyLog.model(.cascadeLeadDeferred, configuration: PrivateIdentifier(first.id))
        }
        // With another model to hop to, a provider's own retry is a wait before the hop, so the
        // hop is the retry (`geminiRetryDelay`).
        cascadeHasAlternative = candidates.count > 1
        defer {
            cascadeHasAlternative = false
            cascadeHasNextCandidate = false
        }
        if routeEvaluated {
            onDeviceJobRouteSettled = true
            pendingJobRouteNotice = routedNotice
        }
        defer {
            onDeviceJobRouteSettled = false
            pendingJobRouteNotice = nil
        }

        let startId = Config.activeModelId
        let historySnapshot = conversationHistory
        let savedById = Dictionary(Config.savedModels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer {
            Config.setActiveModelId(startId)
            refreshActiveModel()
        }

        // How the chain left the lead (if it did) and which candidate's attempt returned, for
        // the memory: a hop away from the lead followed by an answer elsewhere starts the hold.
        var leadHop: ModelFallbackChain.FailureClass?
        var attempting: String?
        let response = try await ModelCascade.run(
            candidates: candidates,
            needs: .init(requiresVision: imageData != nil, isBackgrounded: backgrounded),
            maxAttempts: min(candidates.count, 4),
            isCancelled: { Task.isCancelled },
            beforeHop: { [weak self] error in
                // Plan KL P2: what the tools that already ran decide about the hop.
                try self?.decideHopAfterTools(after: error)
            },
            onSwitch: { from, to, failure, error in
                // Only a hop after the lead was actually tried counts; the driver's pre-attempt
                // capability switch (a lead that cannot see the photo) is not the lead failing.
                if from.id == leadId, attempting == leadId { leadHop = failure }
                // Rewind the partial UI stream and log the hop; P2c narrates it out loud. The
                // error goes in the log too (Plan KL P2): the class alone never said what failed.
                onStreamReset?()
                Self.logCascadeSwitch(to: to.id, failure: failure, error: error)
                await onModelSwitch?(savedById[from.id], savedById[to.id], failure, error)
            },
            attempt: { [weak self] candidate in
                guard let self else { throw LLMError.invalidConfiguration("LLM service released") }
                attempting = candidate.id
                self.cascadeHasNextCandidate = candidate.id != candidates.last?.id
                // Start each attempt from the clean pre-turn history so a failed hop doesn't leave a
                // dangling/duplicated turn, and point the active model at this candidate.
                self.conversationHistory = historySnapshot
                Config.setActiveModelId(candidate.id)
                self.refreshActiveModel()
                return try await send()
            }
        )
        cascadeMemory.recordTurn(lead: leadId, answeredBy: attempting ?? leadId, hop: leadHop, now: Date())
        return response
    }

    // MARK: - Plan-then-execute (Plan S)

    /// Decide whether to route `text` through the plan-then-execute loop (Plan S Phase 2).
    /// The pure keyword heuristic decides for free; when the LLM classifier is enabled and
    /// the request is ambiguous (`ComplexityClassifier.shouldConsultLLM`), a tiny history-free
    /// completion breaks the tie. Any classifier failure falls back to the heuristic.
    private func classifyMultiStep(_ text: String) async -> Bool {
        let heuristic = AgentComplexity.isMultiStep(text)
        guard Config.llmComplexityClassifierEnabled,
              ComplexityClassifier.shouldConsultLLM(text) else {
            return heuristic
        }
        let verdict = (try? await completeStateless(text, system: ComplexityClassifier.systemPrompt))
            .flatMap(ComplexityClassifier.parseVerdict)
        return ComplexityClassifier.decide(heuristic: heuristic, llmVerdict: verdict) == .multiStep
    }

    /// Plan a multi-step request, validate it, and run each step through the supervisor-gated
    /// router. Returns the spoken summary, or nil to fall back to the single-shot tool loop.
    private func runAgentPlan(request: String, nativeToolNames: [String]) async -> String? {
        guard let router = nativeToolRouter else { return nil }
        let mcpNames = router.mcpClient?.discoveredTools.filter { $0.trust.isOffered }.map(\.qualifiedName) ?? []
        let available = nativeToolNames + mcpNames
        guard !available.isEmpty else { return nil }

        let planner = AgentPlanner()
        planner.complete = { [weak self] req, sys in
            guard let self else { return "" }
            return try await self.completeStateless(req, system: sys)
        }
        let runner = AgentRunner(router: router, planner: planner)
        runner.onNarrate = { [weak self] line in self?.onAgentNarrate?(line) }
        runner.onStep = { [weak self] index, total, step in self?.onAgentStep?(index, total, step) }

        guard let result = await runner.run(request: request, availableTools: available) else { return nil }
        PrivacyLog.model(.planLoopCompleted, count: result.completedSteps,
                         total: result.totalSteps, success: !result.aborted)
        return result.summary
    }

    /// A stateless, tools-off completion for the planner: it sees only the system prompt + the
    /// request, never the live conversation history (planning must use trusted context only, and
    /// must not pollute the chat). History is snapshotted and restored even on error.
    /// Stateless, tool-free completion against the user's active provider (honors on-device
    /// models). Used by lightweight features like recall summarization.
    func completeStateless(_ text: String, system: String) async throws -> String {
        // It empties and restores the history, so a scheduled run must not be going under it.
        await yieldOffConversationRun()
        guard let requested = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured")
        }
        let config = try medicalInferenceModel(requested: requested)
        let snapshot = conversationHistory
        conversationHistory = []
        statelessCallDepth += 1
        defer {
            conversationHistory = snapshot
            statelessCallDepth -= 1
        }

        switch config.llmProvider {
        case .anthropic:
            return try await sendAnthropic(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        case .chatgpt:
            return try await sendChatGPT(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        case .gemini, .geminiVertex:
            return try await sendGemini(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        case .local:
            return try await sendLocal(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        case .appleOnDevice:
            return try await sendAppleOnDevice(text, systemPrompt: system,
                                               includeTools: false, carryHistory: false)
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return try await sendOpenAICompatible(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        }
    }

    // MARK: - Scheduled runs, off the conversation

    /// Whether the calling task is a scheduled run's (`sendOffConversation`). Its writes to the
    /// history are its own, and are undone when it ends.
    enum OffConversationScope {
        @TaskLocal static var isActive = false
    }

    /// Thrown by `sendOffConversation` when something that writes the conversation started while
    /// the run was going (the wearer's own turn, a new topic, a loaded thread): the run was
    /// cancelled for it and counts as not run.
    struct OffConversationRunYielded: Error {}

    /// The scheduled run in flight, with the history as it was when the run started.
    private var offConversationRun: (id: UUID, history: [[String: Any]], task: Task<String, Error>)?
    /// Writes to the conversation from outside a run, so a run stopping late never undoes one.
    private var conversationWrites = 0

    /// A scheduled task's prompt, with tools, that reads the conversation as it stands and leaves
    /// nothing in it. A task's prompt used to go into the wearer's history like a turn of theirs:
    /// left there unanswered when the request failed, its "respond with exactly [NOTHING]" was what
    /// the next voice turn's model obeyed instead of the wearer.
    ///
    /// The history is put back as the run found it when the run ends. Anything that writes the
    /// conversation in the meantime ends the run first (`yieldOffConversationRun`), so putting it
    /// back never undoes the wearer's own turn.
    func sendOffConversation(_ text: String, locationContext: String?, memoryContext: String?,
                             agentContext: String?) async throws -> String {
        // One at a time: a second run would start from the first one's history.
        await yieldOffConversationRun()
        let id = UUID()
        let history = conversationHistory
        let task = Task { @MainActor [weak self] () async throws -> String in
            guard let self else { throw LLMError.invalidConfiguration("LLM service released") }
            return try await OffConversationScope.$isActive.withValue(true) {
                try await self.sendMessage(text, locationContext: locationContext,
                                           memoryContext: memoryContext, agentContext: agentContext)
            }
        }
        offConversationRun = (id, history, task)
        let result = await task.result
        // Ended for a write: whatever ended it has put the history back.
        guard offConversationRun?.id == id else { throw OffConversationRunYielded() }
        offConversationRun = nil
        conversationHistory = history
        return try result.get()
    }

    /// End the scheduled run in flight for a write to the conversation, putting the history back
    /// before the write. For the writers that cannot wait; a call from inside the run does nothing.
    /// Returns the run's task, for an async writer to wait on.
    @discardableResult
    private func cancelOffConversationRun() -> Task<String, Error>? {
        guard !OffConversationScope.isActive else { return nil }
        conversationWrites &+= 1
        guard let run = offConversationRun else { return nil }
        offConversationRun = nil
        run.task.cancel()
        conversationHistory = run.history
        PrivacyLog.model(.scheduledRunYielded)
        return run.task
    }

    /// `cancelOffConversationRun`, then wait for the run to stop, so the turn that follows never
    /// runs beside it, and put the history back again if the run wrote to it while stopping.
    private func yieldOffConversationRun() async {
        guard let task = cancelOffConversationRun() else { return }
        let history = conversationHistory
        let writes = conversationWrites
        _ = await task.result
        if conversationWrites == writes { conversationHistory = history }
    }

    /// Clear conversation history (e.g. when starting fresh or switching providers)
    /// Set when a "new topic" arrives while a turn is in flight; applied in `sendMessage`'s defer.
    private var pendingHistoryClear = false

    /// Nesting depth of turns currently running. `isProcessing` tracks only `sendMessage`, which
    /// the on-device agent path bypasses — and a history wipe that lands mid-`sendLocal` is worse
    /// than one that lands mid-`sendMessage`: the turn appends its exchange *after* the clear, so
    /// the "reset" conversation starts holding the very turn it was meant to discard. A depth
    /// rather than a flag because `sendMessage` → `sendLocal` nests.
    private var turnDepth = 0

    /// True while any turn shape is mid-flight. The conversation-reset barrier waits on this, so a
    /// reset requested inside a turn retires context only after the turn has finished owing the
    /// model its tool results.
    var isTurnInFlight: Bool { turnDepth > 0 }

    private func beginTurnScope() { turnDepth += 1 }
    private func endTurnScope() { turnDepth = max(0, turnDepth - 1) }

    /// Clear the conversation history — immediately when idle, or after the in-flight turn
    /// completes when the model itself requested it via the `new_topic` tool (a mid-loop wipe
    /// would orphan the pending tool_result).
    func requestHistoryClear() {
        cancelOffConversationRun()
        if isProcessing {
            pendingHistoryClear = true
        } else {
            clearHistory()
        }
    }

    func clearHistory() {
        cancelOffConversationRun()
        conversationHistory.removeAll()
        toolExposureMemory.removeAll()   // Plan IU: what was looked up belongs to the conversation
        // Plan KK P3: a fresh start for the timeline too, while the saved thread stays open (a model
        // or persona switch). A new topic also starts a new thread; this covers the case where it
        // does not, and a relaunch, which replays the whole thread, clears it again.
        jobHistoryFloor.historyCleared(sessionId: FieldSessionService.shared.activeSession?.id)
    }

    /// Load a persisted conversation thread into the in-memory history.
    /// Called when the user resumes a past conversation from the history view.
    /// The full thread is loaded and then compacted if it exceeds the token budget,
    /// preserving key signals from earlier messages.
    func loadConversationHistory(_ messages: [(role: String, content: String)]) {
        cancelOffConversationRun()
        conversationHistory.removeAll()
        toolExposureMemory.removeAll()   // Plan IU
        for msg in messages {
            conversationHistory.append(["role": msg.role, "content": msg.content])
        }
        jobHistoryFloor.historyReplaced(sessionId: FieldSessionService.shared.activeSession?.id)
        // ChatGPT budgets a copy at submission, retaining the restored evidence.
        if Config.activeModel?.llmProvider != .chatgpt { compressContextWindowIfNeeded() }
        PrivacyLog.model(.historyLoaded, count: conversationHistory.count,
                         total: messages.count)
    }

    /// Compress the context window when estimated token count exceeds the budget.
    ///
    /// Instead of blindly dropping oldest messages, this uses structured compaction:
    /// 1. Extracts key signals from messages about to be removed (decisions, names, memory commands, topics)
    /// 2. Creates a compact summary message that preserves those signals
    /// 3. Replaces the old messages with the summary + keeps recent context intact
    ///
    /// This ensures the agent doesn't "forget" mid-conversation decisions or user facts
    /// even as the raw message history is trimmed for token budget.
    private func compressContextWindowIfNeeded() {
        // Image-aware estimate (Plan BF): a base64 image block is counted by its payload size, not
        // the old 50-token floor, so image-heavy conversations actually trigger compaction.
        let estimatedTokens = HistoryHygiene.estimatedTokens(conversationHistory)

        guard estimatedTokens > maxEstimatedTokens, conversationHistory.count > 6 else { return }

        let originalCount = conversationHistory.count

        // Keep the most recent messages (at least 6 to preserve current thread)
        let keepCount = max(6, conversationHistory.count / 3)
        let messagesToCompress = Array(conversationHistory.prefix(conversationHistory.count - keepCount))
        let messagesToKeep = Array(conversationHistory.suffix(keepCount))

        // Extract key signals from the messages we're about to compress
        var signals: [String] = []
        for msg in messagesToCompress {
            let role = msg["role"] as? String ?? ""
            let content: String
            if let text = msg["content"] as? String {
                content = text
            } else if let parts = msg["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            } else {
                continue
            }

            // Preserve memory commands (they represent decisions the agent made)
            if content.contains("[REMEMBER") || content.contains("[FORGET") {
                let memoryLines = content.components(separatedBy: "\n")
                    .filter { $0.contains("[REMEMBER") || $0.contains("[FORGET") }
                signals.append(contentsOf: memoryLines)
            }

            // Preserve user-stated facts and decisions (short user messages are often important)
            if role == "user" && content.count < 200 {
                signals.append("User said: \(content)")
            }

            // Preserve tool call results (summarized)
            if role == "assistant" && content.contains("tool_use") {
                // Just note which tools were called
                let toolMentions = content.components(separatedBy: "\n")
                    .filter { $0.contains("tool_use") || $0.contains("tool_call") }
                    .prefix(3)
                signals.append(contentsOf: toolMentions)
            }
        }

        // Build a compact summary as a system-role message
        if !signals.isEmpty {
            let summaryContent = "[Earlier conversation context — \(messagesToCompress.count) messages compressed]\n"
                + signals.prefix(20).joined(separator: "\n")
            conversationHistory = [["role": "user", "content": summaryContent]] + messagesToKeep
        } else {
            conversationHistory = messagesToKeep
        }
        jobHistoryFloor.historyCompacted(before: originalCount, after: conversationHistory.count,
                                         insertedSummary: signals.isEmpty ? 0 : 1)

        let newTokens = conversationHistory.reduce(0) { total, msg in
            let content = msg["content"] as? String ?? ""
            return total + max(content.count / 4, 50)
        }

        PrivacyLog.modelCompaction(messagesBefore: originalCount,
                                   messagesAfter: conversationHistory.count,
                                   tokensBefore: estimatedTokens, tokensAfter: newTokens,
                                   signals: signals.count, detail: PrivacyToken("heuristic"))
    }

    // MARK: - Timeline summaries (Plan KK P2)

    /// One summary call for the conversation timeline: tools off, no conversation history, sent to
    /// the model answering this conversation (`medicalInferenceModel` over the active model, never
    /// a cheaper one, which would be a new destination for the wearer's words), and counted in
    /// Usage like every turn.
    ///
    /// Unlike `completeStateless` it never touches `conversationHistory`: the pass runs after a
    /// reply while the next turn may already be under way, and emptying and restoring the history
    /// around the call would wipe whatever that turn added meanwhile. Each provider gets one
    /// buffered request built here, and the reply is read with how it ended, because a note cut off
    /// at the allowance must not be kept.
    ///
    /// Throws `TimelineSummaryError` (or a transport error) rather than returning nil, so the pass
    /// can log why and back off. On-device models are refused: the pass's policy already skips
    /// them, and this keeps a future caller from running background inference on the phone.
    func completeTimelineSummary(_ request: TimelineSummaryPrompt.Request) async throws -> TimelineSummaryCompletion {
        guard let requested = Config.activeModel else { throw TimelineSummaryError.unavailable }
        let config = try medicalInferenceModel(requested: requested)
        guard !RelationEnrichmentPolicy.isOnDevice(config.llmProvider) else {
            throw TimelineSummaryError.unavailable
        }
        try enforceMedicalRemoteBoundary(config)
        let provider = config.llmProvider
        let timeout: TimeInterval = 45

        switch provider {
        case .anthropic:
            let body = AnthropicRequest.body(
                model: config.model, maxTokens: request.maxTokens, system: .text(request.system),
                messages: [["role": "user", "content": request.user]],
                reasoning: config.reasoningResolution(toolsAttached: false))
            let (urlRequest, account) = try await anthropicURLRequest(config: config, body: body, timeout: timeout)
            let (data, response) = try await anthropicData(for: urlRequest, account: account)
            Self.noteAnthropicRejection(response: response, body: data, request: urlRequest, detail: "timelineSummary")
            let json = try Self.timelineSummaryJSON(data, response)
            recordUsage(provider: provider, model: config.model, json: json)
            return try TimelineSummaryReply.anthropic(json)

        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            let baseURL = Self.chatCompletionsURLString(baseURL: config.baseURL, provider: provider)
            guard let url = URL(string: baseURL) else { throw TimelineSummaryError.unavailable }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let credential = await openAICompatibleCredential(config)
            urlRequest.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            urlRequest.timeoutInterval = timeout
            var body: [String: Any] = [
                "model": config.model,
                // A model that reasons by default draws its reasoning from the same allowance.
                "max_tokens": config.oneShotReasoningResolution().outputCap(base: request.maxTokens),
                "messages": [
                    ["role": "system", "content": request.system],
                    ["role": "user", "content": request.user],
                ],
            ]
            Self.applyGroqOneShotReasoning(to: &body, config: config)
            Self.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: baseURL)
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await dataSession.consentedData(
                for: urlRequest, scope: .conversation, consent: processingConsent)
            let json = try Self.timelineSummaryJSON(data, response)
            recordUsage(provider: provider, model: config.model, json: json)
            return try TimelineSummaryReply.chatCompletions(json)

        case .gemini, .geminiVertex:
            var urlRequest = try await geminiRequest(for: config, timeout: timeout)
            let body: [String: Any] = [
                "system_instruction": ["parts": [["text": request.system]]],
                "contents": [["role": "user", "parts": [["text": request.user]]]],
                "generationConfig": config.oneShotReasoningResolution()
                    .geminiOneShotGenerationConfig(maxTokens: request.maxTokens),
            ]
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await dataSession.consentedData(
                for: urlRequest, scope: .conversation, consent: processingConsent)
            let json = try Self.timelineSummaryJSON(data, response)
            recordUsage(provider: provider, model: config.model, json: json)
            return try TimelineSummaryReply.gemini(json)

        case .chatgpt:
            // The subscription backend has no reply allowance to run into; its usage counts as
            // any ChatGPT turn's does, though the subscription is not billed per token.
            guard let json = await chatgptStatelessResponse(
                model: config.model, instructions: request.system, userContent: request.user,
                timeout: timeout) else { throw TimelineSummaryError.rejected }
            recordUsage(provider: provider, model: config.model, json: json)
            return try TimelineSummaryReply.responses(json)

        case .local, .appleOnDevice:
            throw TimelineSummaryError.unavailable
        }
    }

    /// The JSON body of a successful buffered reply, or the reason there is none.
    private nonisolated static func timelineSummaryJSON(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TimelineSummaryError.rejected
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TimelineSummaryError.unreadable
        }
        return json
    }

    /// Whether the spend caps stop the timeline pass for the active model now
    /// (`TimelinePassPolicy.isAtSpendCap`). Priced spend comes from the local usage store.
    func timelineSpendCapReached(now: Date = Date()) -> Bool {
        guard let requested = Config.activeModel,
              let config = try? medicalInferenceModel(requested: requested) else { return false }
        let caps = SpendCapPolicy.Caps(dailyUSD: Config.dailySpendCapUSD,
                                       monthlyUSD: Config.monthlySpendCapUSD,
                                       fallBackToCheaperModel: Config.spendCapFallbackToCheaperModel)
        guard !caps.isEmpty else { return false }
        let spent = (usageTrackerOverride ?? UsageTracker.shared).spend(now: now)
        let decision = SpendCapPolicy.decide(spentToday: spent.today, spentMonth: spent.month, caps: caps,
                                             pricing: Self.spendPricing(config),
                                             overrideKey: nil, now: now)
        return TimelinePassPolicy.isAtSpendCap(decision)
    }

    /// Stateless one-shot vision analysis: sends `systemPrompt` + `userText` + a JPEG frame to the
    /// active provider with no tools and a small token budget, and does NOT mutate conversation
    /// history. Used by the Assistive Modes (A3) ambient loop, which must not pollute the chat.
    /// Returns the raw model text, or nil on failure / unsupported provider (local, appleOnDevice).
    func analyzeFrame(systemPrompt: String, userText: String, imageData: Data, maxTokens: Int = 200) async -> String? {
        guard let requestedModel = Config.activeModel,
              let modelConfig = try? medicalInferenceModel(requested: requestedModel) else { return nil }
        let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
        let provider = modelConfig.llmProvider

        do {
            switch provider {
            case .anthropic:
                return try await anthropicOneShotText(
                    config: modelConfig, system: systemPrompt,
                    userContent: [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                        ["type": "text", "text": userText]
                    ] as [[String: Any]],
                    maxTokens: maxTokens, timeout: 20, detail: "analyzeFrame")

            case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let credential = await openAICompatibleCredential(modelConfig)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 20
                var body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "messages": [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": [
                            ["type": "text", "text": userText],
                            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                        ]]
                    ]
                ]
                Self.applyQwenReasoning(to: &body, provider: provider, model: modelConfig.model, disableThinking: true)
                Self.applyGroqOneShotReasoning(to: &body, config: modelConfig)
                Self.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: baseURL)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String else { return nil }
                return Self.stripThinkTags(text).spoken

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 20) else { return nil }
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": [
                        ["text": userText],
                        ["inlineData": ["mimeType": "image/jpeg", "data": base64]]
                    ]]],
                    "generationConfig": modelConfig.oneShotReasoningResolution()
                        .geminiOneShotGenerationConfig(maxTokens: maxTokens)
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let text = parts.first?["text"] as? String else { return nil }
                return text

            case .chatgpt:
                guard let json = await chatgptStatelessResponse(
                    model: modelConfig.model, instructions: systemPrompt,
                    userContent: [
                        ["type": "text", "text": userText],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ] as [[String: Any]],
                    timeout: 20) else { return nil }
                let text = ResponsesTranslator.parseOutput(json).text
                return text.isEmpty ? nil : text

            case .local, .appleOnDevice:
                return nil
            }
        } catch {
            PrivacyLog.model(.requestFailed, detail: PrivacyToken("analyzeFrame"),
                             error: SafeErrorSummary(error))
            return nil
        }
    }

    /// Stateless one-shot STRUCTURED vision analysis (structured-vision plan, Phase 2): like
    /// `analyzeFrame`, but forces the active provider to return a JSON object matching `jsonSchema` —
    /// Anthropic forced `tool_choice`, OpenAI-compatible forced function, Gemini JSON response. The
    /// pure `StructuredVisionParser` extracts the object and also falls back to tolerant parsing of any
    /// returned text, so a model that answers with prose JSON still yields a result. Does NOT mutate
    /// conversation history. Returns the JSON object, or nil on failure / unsupported provider
    /// (local, appleOnDevice). The caller decodes/validates against its schema.
    func analyzeFrameStructured(systemPrompt: String, userText: String, imageData: Data,
                                jsonSchema: [String: Any], toolName: String = "assessment",
                                maxTokens: Int = 1024) async -> [String: Any]? {
        guard let requestedModel = Config.activeModel,
              let modelConfig = try? medicalInferenceModel(requested: requestedModel) else { return nil }
        let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
        let provider = modelConfig.llmProvider
        let toolDescription = "Return the structured assessment for the image."

        do {
            switch provider {
            case .anthropic:
                return try await anthropicStructured(
                    config: modelConfig, system: systemPrompt,
                    userContent: [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                        ["type": "text", "text": userText]
                    ] as [[String: Any]],
                    tool: .init(name: toolName, description: toolDescription, schema: jsonSchema),
                    maxTokens: maxTokens, timeout: 30, detail: "analyzeFrameStructured")

            case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let credential = await openAICompatibleCredential(modelConfig)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 30
                var body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "messages": [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": [
                            ["type": "text", "text": userText],
                            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]]
                        ]]
                    ],
                    "tools": [["type": "function", "function": [
                        "name": toolName, "description": toolDescription, "parameters": jsonSchema]]],
                    "tool_choice": ["type": "function", "function": ["name": toolName]]
                ]
                Self.applyGroqOneShotReasoning(to: &body, config: modelConfig)
                Self.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: baseURL)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.openAI(data)

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 30) else { return nil }
                // `responseMimeType` + a translated `responseSchema` enforce the exact JSON shape
                // (not just "some JSON") — the Gemini equivalent of Anthropic/OpenAI forced tool-use.
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": [
                        ["text": userText],
                        ["inlineData": ["mimeType": "image/jpeg", "data": base64]]
                    ]]],
                    "generationConfig": modelConfig.oneShotReasoningResolution()
                        .geminiOneShotGenerationConfig(maxTokens: maxTokens)
                        .merging([
                            "responseMimeType": "application/json",
                            "responseSchema": GeminiSchemaTranslator.translate(jsonSchema)
                        ]) { _, shape in shape }
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.gemini(data)

            case .chatgpt:
                return await chatgptStatelessStructured(
                    model: modelConfig.model, instructions: systemPrompt,
                    userContent: [
                        ["type": "text", "text": userText],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
                    ] as [[String: Any]],
                    toolName: toolName, toolDescription: toolDescription, jsonSchema: jsonSchema)

            case .local, .appleOnDevice:
                // On-device structured vision isn't supported here; the caller may fall back.
                return nil
            }
        } catch {
            PrivacyLog.model(.requestFailed, detail: PrivacyToken("analyzeFrameStructured"),
                             error: SafeErrorSummary(error))
            return nil
        }
    }

    /// Stateless TEXT → JSON structured completion (no image, no conversation history) — the text sibling
    /// of `analyzeFrameStructured`. Cloud providers use forced tool-use / JSON mode; the on-device
    /// providers (Apple Foundation Models / local MLX) are prompted for JSON and parsed tolerantly, so
    /// the offline path works. Returns the JSON object, or nil on failure. Used by Study Mode generation.
    func completeStructured(systemPrompt: String, userText: String, jsonSchema: [String: Any],
                            toolName: String = "result", maxTokens: Int = 2048) async -> [String: Any]? {
        guard let requestedModel = Config.activeModel,
              let modelConfig = try? medicalInferenceModel(requested: requestedModel) else { return nil }
        let provider = modelConfig.llmProvider
        let toolDescription = "Return the structured result."

        do {
            switch provider {
            case .anthropic:
                return try await anthropicStructured(
                    config: modelConfig, system: systemPrompt, userContent: userText,
                    tool: .init(name: toolName, description: toolDescription, schema: jsonSchema),
                    maxTokens: maxTokens, timeout: 45, detail: "completeStructured")

            case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let credential = await openAICompatibleCredential(modelConfig)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 45
                var body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "messages": [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": userText]
                    ],
                    "tools": [["type": "function", "function": [
                        "name": toolName, "description": toolDescription, "parameters": jsonSchema]]],
                    "tool_choice": ["type": "function", "function": ["name": toolName]]
                ]
                Self.applyGroqOneShotReasoning(to: &body, config: modelConfig)
                Self.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: baseURL)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.openAI(data)

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 45) else { return nil }
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": [["text": userText]]]],
                    "generationConfig": modelConfig.oneShotReasoningResolution()
                        .geminiOneShotGenerationConfig(maxTokens: maxTokens)
                        .merging([
                            "responseMimeType": "application/json",
                            "responseSchema": GeminiSchemaTranslator.translate(jsonSchema)
                        ]) { _, shape in shape }
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.gemini(data)

            case .chatgpt:
                return await chatgptStatelessStructured(
                    model: modelConfig.model, instructions: systemPrompt, userContent: userText,
                    toolName: toolName, toolDescription: toolDescription, jsonSchema: jsonSchema)

            case .appleOnDevice:
                let prompt = systemPrompt + "\n\nReturn ONLY a single valid JSON object matching the requested shape — no prose, no code fences."
                let text = try await sendAppleOnDevice(userText, systemPrompt: prompt,
                                                       includeTools: false, carryHistory: false)
                return AssessmentJSON.object(fromText: text)

            case .local:
                let prompt = systemPrompt + "\n\nReturn ONLY a single valid JSON object — no prose, no code fences."
                let text = try await sendLocal(userText, systemPrompt: prompt, config: modelConfig, includeTools: false)
                return AssessmentJSON.object(fromText: text)
            }
        } catch {
            PrivacyLog.model(.requestFailed, detail: PrivacyToken("completeStructured"),
                             error: SafeErrorSummary(error))
            return nil
        }
    }

    /// Refresh the published model name from Config
    func refreshActiveModel() {
        activeModelName = Config.activeModel?.name ?? "No Model"
    }

    func invalidateOnDeviceSession() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            appleToolCache = nil
        }
        #endif
    }

    // MARK: - Anthropic Claude

    /// Capture the token usage block from a provider's response JSON and hand it to
    /// the cost tracker (Plan AU). Parsing is pure/synchronous here; only the resulting
    /// integer counts cross to the main actor (the non-Sendable JSON does not). A
    /// missing usage block is a silent no-op — never throws, never blocks the reply.
    /// Streaming turns accumulate their own counts via `StreamingUsageAccumulator` and
    /// enter through the already-parsed overload below.
    private func recordUsage(provider: LLMProvider, model: String, json: [String: Any]) {
        guard let usage = UsageTracker.parseUsage(provider: provider, json: json) else { return }
        // A usage block that carried none of the expected keys is shape drift, not a
        // free turn — mark it so it isn't silently lost (Plan BM P3).
        guard usage.recognized else {
            let tracker = usageTrackerOverride ?? UsageTracker.shared
            Task { @MainActor in tracker.noteUntrackedTurn() }
            return
        }
        recordUsage(provider: provider, model: model, tokensIn: usage.tokensIn, tokensOut: usage.tokensOut,
                    cacheWriteTokens: usage.cacheWriteTokens, cacheReadTokens: usage.cacheReadTokens)
    }

    /// Record already-parsed token counts (the streaming paths accumulate their own).
    private func recordUsage(provider: LLMProvider, model: String, tokensIn: Int, tokensOut: Int,
                             cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0) {
        guard tokensIn + tokensOut + cacheWriteTokens + cacheReadTokens > 0 else { return }
        // Plan GB P5: tag the call with the job it served, read now rather than when the record
        // lands, so a turn that closes the job still counts toward it.
        let fieldSessionId = FieldSessionService.shared.activeSession?.id
        let tracker = usageTrackerOverride ?? UsageTracker.shared
        Task { @MainActor in
            tracker.record(provider: provider, model: model, tokensIn: tokensIn, tokensOut: tokensOut,
                           cacheWriteTokens: cacheWriteTokens, cacheReadTokens: cacheReadTokens,
                           fieldSessionId: fieldSessionId)
        }
    }

    // MARK: Anthropic one-shot calls (Plan IE P1)

    /// A prepared Anthropic request: the endpoint, the credential, and a body built by
    /// `AnthropicRequest` — the one place that knows what this model accepts.
    /// The account token rides back beside it when the credential came from the Claude sign-in,
    /// so a 401 can force one refresh (Plan FG P1a).
    private func anthropicURLRequest(config: ModelConfig, body: [String: Any],
                                     timeout: TimeInterval) async throws -> (URLRequest, SubscriptionAuthRetry.Credential?) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credential = await AnthropicAuth.resolveCredential(apiKey: config.apiKey, account: claudeAccount)
        AnthropicAuth.apply(credential: credential, to: &request)
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (request, anthropicAccountCredential(config: config, credential: credential))
    }

    /// The credential a 401 may refresh: only a token the Claude sign-in supplied, never a key.
    private func anthropicAccountCredential(config: ModelConfig, credential: String) -> SubscriptionAuthRetry.Credential? {
        guard AnthropicAuth.usesAccountSignIn(apiKey: config.apiKey), !credential.isEmpty else { return nil }
        return SubscriptionAuthRetry.Credential(credential)
    }

    /// A replacement for a Claude account token the endpoint refused, or nil when there is none.
    private func refreshedClaudeToken(after rejected: String) async -> String? {
        await claudeAccount.accessToken(afterRejecting: rejected)
    }

    /// One buffered Anthropic request, with the account route's forced refresh on a 401.
    private func anthropicData(for request: URLRequest,
                               account: SubscriptionAuthRetry.Credential?) async throws -> (Data, URLResponse) {
        try await SubscriptionAuthRetry.send(
            request, credential: account, provider: "anthropic",
            refresh: { await self.refreshedClaudeToken(after: $0) },
            sign: { token, request in AnthropicAuth.apply(credential: token, to: &request) },
            refused: { SubscriptionAuthRetry.isUnauthorized($0.1) },
            attempt: { try await self.dataSession.consentedData(for: $0, scope: .conversation, consent: self.processingConsent) })
    }

    /// One stateless Anthropic call that wants text back: the summariser and the one-shot frame
    /// analysis. The text is taken from the reply's `text` blocks by type — a model that thinks
    /// by default opens with a thinking block, and reading the first block returned nothing while
    /// the answer sat in the second. Returns nil on a refusal, a declined reply or an empty one.
    ///
    /// Internal so the fixture tests can drive it with a config and a stubbed `dataSession`.
    func anthropicOneShotText(config: ModelConfig, system: String, userContent: Any,
                              maxTokens: Int, timeout: TimeInterval, detail: String) async throws -> String? {
        let body = AnthropicRequest.body(
            model: config.model, maxTokens: maxTokens, system: .text(system),
            messages: [["role": "user", "content": userContent]],
            reasoning: config.reasoningResolution(toolsAttached: false))
        let (request, account) = try await anthropicURLRequest(config: config, body: body, timeout: timeout)
        let (data, response) = try await anthropicData(for: request, account: account)
        Self.noteAnthropicRejection(response: response, body: data, request: request, detail: detail)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return AnthropicReply.oneShotText(from: data)
    }

    /// One stateless Anthropic call that wants a JSON object back through a single tool:
    /// structured vision and its text sibling.
    ///
    /// Where the model takes a forced tool choice the request is what it always was. Where it
    /// does not, the request asks for the call in words, and a model asked in words can answer in
    /// prose instead: `StructuredVisionParser` reads prose JSON too, and a reply that yields
    /// nothing either way is asked for once more. A refused request is not retried — the same
    /// body would be refused again.
    func anthropicStructured(config: ModelConfig, system: String, userContent: Any,
                             tool: AnthropicRequest.AnswerTool, maxTokens: Int,
                             timeout: TimeInterval, detail: String) async throws -> [String: Any]? {
        let contract = AnthropicModelContract.contract(for: config.model)
        let body = AnthropicRequest.body(
            model: config.model, maxTokens: maxTokens, system: .text(system),
            messages: [["role": "user", "content": userContent]],
            answerTool: tool, reasoning: config.reasoningResolution(toolsAttached: true))
        let (request, account) = try await anthropicURLRequest(config: config, body: body, timeout: timeout)

        let attempts = contract.allowsForcedToolChoice ? 1 : 2
        for attempt in 1...attempts {
            let (data, response) = try await anthropicData(for: request, account: account)
            Self.noteAnthropicRejection(response: response, body: data, request: request, detail: detail)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let object = StructuredVisionParser.anthropic(data, toolName: tool.name) { return object }
            if attempt < attempts {
                PrivacyLog.model(.structuredRetry, provider: PrivacyToken("anthropic"),
                                 model: PrivacyToken(config.model), detail: PrivacyToken(detail))
            }
        }
        return nil
    }

    // Internal (not private) so the BM P9 fixture tests can drive the full streamed tool loop
    // through a stubbed `streamingSession`.
    func sendAnthropic(_ text: String, systemPrompt: String, volatileTail: String? = nil, config: ModelConfig, includeTools: Bool, imageData: Data?, smallContext: Bool = false, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        try enforceMedicalRemoteBoundary(config)
        // An explicit API key wins; otherwise fall back to a connected Claude account (OAuth).
        let apiKey = await AnthropicAuth.resolveCredential(apiKey: config.apiKey, account: claudeAccount)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey(claudeAccount.isConnected
                ? (claudeAccount.lastError ?? LLMProvider.anthropic.missingCredentialMessage)
                : LLMProvider.anthropic.missingCredentialMessage)
        }
        // Which kind of credential this turn is sent with, never the value (Plan IE P0): a failed
        // turn's line in the support report says whether a key or an account sign-in was refused.
        TurnRecorder.noteCredential(AnthropicAuth.kind(of: apiKey))
        // Plan FG P1a: an account token a 401 refreshes once; every later round sends the new one.
        let account = anthropicAccountCredential(config: config, credential: apiKey)

        // A new user turn: nothing older than it may hold a thinking block (Plan IE P2). Here as
        // well as in `sendMessage`, because the agent tier and the tests enter at this function.
        conversationHistory = HistoryHygiene.stripThinkingBlocks(conversationHistory)

        // Add user message to history
        if let imageData = imageData {
            let base64String = LLMImagePreparer.prepared(imageData).base64EncodedString()
            let content: [[String: Any]] = [
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64String
                    ]
                ],
                [
                    "type": "text",
                    "text": text
                ]
            ]
            conversationHistory.append(["role": "user", "content": content])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()
        turnHistoryStart = max(0, conversationHistory.count - 1)
        // Plan KZ: a provider search's blocks are replayed unchanged within the turn, and leave
        // the history with it, however it ends — a later request may not declare the tool.
        defer { conversationHistory = HistoryHygiene.stripProviderSearchBlocks(conversationHistory) }
        let searchTurn = ProviderSearchTurn(credential: apiKey)

        // A tool_use block with an id but missing name/input can't be dispatched, yet still needs a
        // tool_result or the next request 400s (Plan BF). Its id is carried per-turn and answered
        // with a synthetic error alongside the real results.
        final class TurnState {
            var malformedIds: [String] = []
            /// What the previous request of this turn sent (Plan IE P2), so the next one can tell
            /// whether the thinking blocks produced since may be replayed.
            var lastSent: ThinkingReplayGuard.Sent?
        }
        let state = TurnState()

        // Raised for the wrap-up request only, which then offers the model no tool to call.
        let withholding = ToolWithholding()
        let adapter = ProviderLoopAdapter(
            label: "Anthropic",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("Anthropic") }
                // Plan KZ: a `pause_turn` is resumed once, by sending the paused content back as
                // it is; a second pause is taken as the answer so far.
                var resumedPause = false
                for _ in 0..<2 {
                    state.malformedIds = []

                    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    AnthropicAuth.apply(credential: account?.token ?? apiKey, to: &request)  // resolved above

                    // Turn hygiene (Plan BF): drop stale images that would otherwise re-upload every turn,
                    // and repair any dangling tool_use so a single interrupted tool call can't 400 the whole
                    // conversation. Applied to the sent copy AND written back so the fixes persist.
                    self.conversationHistory = HistoryHygiene.repairDanglingToolUse(
                        HistoryHygiene.pruneImages(self.conversationHistory, keepLast: 1))

                    var historyForRequest = self.requestHistory(for: config.llmProvider, smallContext: smallContext)
                    let reasoning = config.reasoningResolution(toolsAttached: includeTools)
                    Self.noteReasoning(reasoning, provider: .anthropic, model: config.model)

                    // Prompt caching (Plan BF): the system prompt + tool schemas are large and byte-stable
                    // within a session, so mark them ephemeral-cacheable. Anthropic then reads them from
                    // cache on every follow-up turn instead of re-billing full input tokens each time.
                    // Plan GB P5: the breakpoint sits on the *untimestamped* head; the volatile tail
                    // (date and time, memory, passages) follows as its own uncached block. The tools
                    // come first: the omission note offers `brain` only when it is declared.
                    var tools: [[String: Any]] = []
                    // Plan KZ: the provider's own web search, when this request carries it.
                    var attachedSearch: ProviderSearchSpec?
                    if includeTools {
                        let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                        let declaring = self.roundToolFilter()   // Plan IU: nil = every tool
                        let (toolsData, mcpToolCount): (Data, Int) = await MainActor.run {
                            let mcpClient = self.nativeToolRouter?.mcpClient
                            let tools = ToolDeclarations.anthropicTools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: mcpClient, declaring: declaring)
                            let data = (try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])) ?? Data()
                            return (data, ToolDeclarations.mcpToolDeclarations(mcpClient: mcpClient).count)
                        }
                        tools = (try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? []
                        // Plan KZ: when Claude searches itself, our `web_search` is withheld, so one
                        // question is never searched twice (Decision 3).
                        if let spec = await self.providerSearchSpec(
                            for: config, turn: searchTurn,
                            declaresWebSearch: ProviderSearchPolicy.declaresOurTool(tools),
                            kinds: [.anthropic]) {
                            attachedSearch = spec
                            tools = ProviderSearchPolicy.withholdingOurTool(tools)
                        }
                        // Dropped mid-turn: the copy above still carries the search's blocks.
                        if searchTurn.takeHistoryChanged() {
                            historyForRequest = self.requestHistory(for: config.llmProvider, smallContext: smallContext)
                        }
                        // How many definitions went, and how many of them an MCP server wrote — the
                        // one part of the body that differs between installations. Counts only.
                        TurnRecorder.noteToolsSent(count: tools.count, fromMCP: mcpToolCount)
                        // Cache-breakpoint on the final tool caches the whole tools array as one prefix.
                        if !tools.isEmpty {
                            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
                        }
                        // After the breakpoint: the system block's own breakpoint still covers it.
                        if let attachedSearch { tools.append(attachedSearch.toolFragment) }
                    }
                    let (promptForRound, tailForRound) = Self.withProviderSearchSentence(
                        attachedSearch, systemPrompt: systemPrompt, volatileTail: volatileTail)
                    let recallOffered = includeTools && !withholding.active && APIHistoryBudget.declaresRecall(tools)
                    var system = self.requestSystemParts(stable: promptForRound, volatileTail: tailForRound,
                                                         recallOffered: recallOffered)
                    var systemBlocks = PromptLayout.anthropicSystem(stable: system.stable, volatile: system.volatile)

                    // Plan IE P2: this turn's thinking blocks ride only over the prefix they were
                    // produced over. The hygiene and the budget above can rewrite an earlier message
                    // between round trips (a pruned photo, a dropped exchange, a changed omission
                    // note), so compare with what the last request sent; on any difference drop the
                    // blocks — from the history too, so every later request sends the same thing.
                    if let lastSent = state.lastSent, HistoryHygiene.containsThinking(historyForRequest),
                       !ThinkingReplayGuard.prefixUnchanged(since: lastSent, system: systemBlocks,
                                                            tools: tools, messages: historyForRequest) {
                        self.conversationHistory = HistoryHygiene.stripThinkingBlocks(self.conversationHistory)
                        historyForRequest = self.requestHistory(for: config.llmProvider, smallContext: smallContext)
                        system = self.requestSystemParts(stable: promptForRound, volatileTail: tailForRound,
                                                         recallOffered: recallOffered)
                        systemBlocks = PromptLayout.anthropicSystem(stable: system.stable, volatile: system.volatile)
                        PrivacyLog.model(.thinkingDropped, provider: PrivacyToken("anthropic"),
                                         model: PrivacyToken(config.model))
                    }
                    state.lastSent = ThinkingReplayGuard.record(system: systemBlocks, tools: tools,
                                                                messages: historyForRequest)

                    // Plan IE P1/P3: the body comes from the one builder that knows what this model
                    // accepts — the effort it is sent, and output room for the thinking it does.
                    let baseOutputCap = smallContext
                        ? (imageData != nil ? Self.smallContextVisionMaxTokens : Config.maxTokens)
                        : (includeTools ? Self.toolTurnMaxTokens : Config.maxTokens)
                    var body = AnthropicRequest.body(
                        model: config.model, maxTokens: baseOutputCap, system: .blocks(systemBlocks),
                        messages: historyForRequest, tools: includeTools ? tools : nil,
                        reasoning: reasoning, stream: onToken != nil)
                    if withholding.active, includeTools, !tools.isEmpty {
                        body["tool_choice"] = ["type": "none"]
                    }
                    // Sorted keys: byte-identical bodies for identical content (Plan GB P5).
                    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

                    // Final-reply turns stream into the Chat tab when a streaming caller passes `onToken`;
                    // the reconstructed content blocks + stop reason feed the shared tool loop unchanged.
                    let content: [[String: Any]]
                    let stopReason: String?
                    var searchUsage: [String: Any]?
                    if let onToken {
                        // New tool-loop iteration: clear the caller's accumulated bubble first, so an
                        // intermediate tool turn's text never concatenates with the final reply (BM P9).
                        onStreamReset?()
                        let flag = TokenDeliveryFlag()
                        (content, stopReason) = try await SubscriptionAuthRetry.send(
                            request, credential: account, provider: "anthropic",
                            refresh: { await self.refreshedClaudeToken(after: $0) },
                            sign: { token, request in AnthropicAuth.apply(credential: token, to: &request) }
                        ) { request in
                            try await self.withTransientSSERetries(tokenFlag: flag) {
                                try await self.streamAnthropicContent(request: request, model: config.model) { token in
                                    flag.mark()
                                    onToken(token)
                                }
                            }
                        }
                    } else {
                        let data: Data = try await SubscriptionAuthRetry.send(
                            request, credential: account, provider: "anthropic",
                            refresh: { await self.refreshedClaudeToken(after: $0) },
                            sign: { token, request in AnthropicAuth.apply(credential: token, to: &request) }
                        ) { request in
                            let (data, response) = try await self.dataSession.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                            guard let httpResponse = response as? HTTPURLResponse,
                                  httpResponse.statusCode == 200 else {
                                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                                // Logged whether or not the body parsed: a refusal with no readable
                                // envelope used to leave no line at all (Plan IE P0).
                                let rejection = Self.noteAnthropicRejection(response: response, body: data,
                                                                            request: request)
                                let errorMsg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                                throw LLMError.apiError(provider: "Anthropic", statusCode: statusCode,
                                                        message: errorMsg, rejection: rejection)
                            }
                            return data
                        }

                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let parsed = json["content"] as? [[String: Any]] else {
                            throw LLMError.invalidResponse("Anthropic")
                        }
                        content = parsed
                        stopReason = json["stop_reason"] as? String
                        searchUsage = json["usage"] as? [String: Any]
                        self.recordUsage(provider: .anthropic, model: config.model, json: json)
                    }
                    if let attachedSearch {
                        self.absorbProviderSearch(ProviderSearchEvidence.anthropic(content: content, usage: searchUsage),
                                                  spec: attachedSearch, config: config, turn: searchTurn)
                    }

                    var toolCalls: [ToolInvocation] = []
                    if stopReason == "tool_use", includeTools {
                        for block in content where (block["type"] as? String) == "tool_use" {
                            if let id = block["id"] as? String,
                               let name = block["name"] as? String,
                               let input = block["input"] as? [String: Any] {
                                toolCalls.append(ToolInvocation(id: id, name: name, arguments: input))
                            } else if let id = block["id"] as? String {
                                state.malformedIds.append(id)
                            }
                        }
                    }
                    let text = AnthropicReply.text(in: content)
                    // Plan IE P3: a 200 that is not an answer says so, instead of reaching `finalize`
                    // as an empty reply and surfacing as an unreadable response.
                    switch AnthropicReply.outcome(stopReason: stopReason, text: text,
                                                  hasToolCalls: !toolCalls.isEmpty || !state.malformedIds.isEmpty) {
                    case .declined: throw LLMError.modelDeclined(provider: "Anthropic")
                    case .ranOutOfRoom: throw LLMError.outputTruncated(provider: "Anthropic")
                    case .paused where !resumedPause:
                        resumedPause = true
                        PrivacyLog.model(.providerSearch, provider: PrivacyToken("anthropic"),
                                         detail: PrivacyToken("pauseTurnResumed"))
                        self.conversationHistory.append(["role": "assistant", "content": content] as [String: Any])
                        continue
                    case .answered, .paused: break
                    }
                    return AssistantTurn(text: text, toolCalls: toolCalls, payload: content)
                }
                throw LLMError.invalidResponse("Anthropic")
            },
            appendAssistantToolCall: { [weak self] turn in
                guard let self, let content = turn.payload as? [[String: Any]] else { return }
                self.conversationHistory.append(["role": "assistant", "content": content] as [String: Any])
            },
            appendToolResults: { [weak self] outcomes in
                guard let self else { return }
                for outcome in outcomes {
                    guard let id = outcome.invocation.id else { continue }
                    let resultContent: String
                    switch outcome.result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }
                    // A capture tool returns its photo as a base64 marker inside its text. Send it
                    // as pixels — a transcript of an image is not an image (issue 427).
                    let split = ToolResultImage.extract(from: resultContent)
                    let canSeeIt = split.image != nil && config.visionEnabled
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(
                        toolName: outcome.invocation.name,
                        content: split.image != nil && !canSeeIt
                            ? ToolResultImage.textWithImageOmitted(split.text)
                            : split.text)
                    var toolResult: [String: Any] = [
                        "type": "tool_result", "tool_use_id": id, "content": framed,
                    ]
                    if canSeeIt, let image = split.image {
                        // Anthropic tool_result content takes the same typed blocks a user turn
                        // does, so the image rides inside the result itself.
                        toolResult["content"] = [
                            ["type": "text", "text": framed],
                            ["type": "image",
                             "source": ["type": "base64", "media_type": "image/jpeg",
                                        "data": image.base64EncodedString()]],
                        ]
                    }
                    self.conversationHistory.append([
                        "role": "user", "content": [toolResult],
                    ] as [String: Any])
                }
                for id in state.malformedIds {
                    self.conversationHistory.append([
                        "role": "user",
                        "content": [["type": "tool_result", "tool_use_id": id,
                                     "content": "Error: malformed tool call (missing name or arguments); nothing was run."]]
                    ] as [String: Any])
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse("Anthropic") }
                guard !turn.text.isEmpty else { throw LLMError.invalidResponse("Anthropic") }
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                return turn.text
            }
        )

        return try await retryingWithoutProviderSearch(config: config, turn: searchTurn,
                                                        onStreamReset: onStreamReset) {
            try await runToolLoop(maxIterations: self.toolLoopIterations,
                                       adapter: self.notingStalls(adapter).withholdingTools(withholding),
                                       setStatus: { [weak self] in self?.toolCallStatus = $0 })
        }
    }

    // MARK: - Provider-run web search (Plan KZ)

    /// The request's instructions with the provider-search sentence (§5, §6) when a search rides
    /// on it: in the uncached tail where the request has one, so the cached head is unchanged.
    nonisolated static func withProviderSearchSentence(_ spec: ProviderSearchSpec?, systemPrompt: String,
                                                       volatileTail: String?) -> (String, String?) {
        guard let spec else { return (systemPrompt, volatileTail) }
        let sentence = ProviderSearchPolicy.promptSentence(maxUses: spec.maxUses)
        if let volatileTail { return (systemPrompt, volatileTail + "\n\n" + sentence) }
        return (systemPrompt + "\n\n" + sentence, nil)
    }

    /// The provider search to attach to this round, or nil for our own tool.
    ///
    /// Decided by `ProviderSearchPolicy` from the live settings. Once a turn attaches it, it stays
    /// for the turn's every round: a search block replayed into the next round needs its tool. A
    /// turn retried after a refusal uses our tool throughout. `kinds` are the searches this send
    /// path can carry; anything else leaves our tool in place without asking for consent. The
    /// first attachment asks Cloud AI Sharing's "Web search" question for the conversation host
    /// (§10); anything but a yes is our tool.
    private func providerSearchSpec(for config: ModelConfig, turn: ProviderSearchTurn,
                                    declaresWebSearch: Bool,
                                    kinds: Set<ProviderSearchSpec.Kind>) async -> ProviderSearchSpec? {
        if turn.forcedOurTool { return nil }
        let inputs = ProviderSearchLive.inputs(
            for: config, credential: turn.credential, webSearchDeclared: declaresWebSearch,
            learnedResponsesRejection: Self.responsesRouteRejections.contains(config.model),
            memory: providerSearchMemory)
        // Settled: the turn's search, if this path can carry it (a Responses turn that fell back
        // to Chat Completions cannot) — and only while the boundaries still allow it. They are
        // read every round: a tool in round one can seal a vault-only job, and the medical
        // boundary can come on mid-turn. Then the search goes for the rest of the turn, and so do
        // its blocks in this turn's history, which the next request could not carry without the
        // tool (review follow-up 2026-11-10). The consent answer stays settled.
        if turn.settled {
            if turn.spec != nil, let reason = ProviderSearchPolicy.boundary(inputs) {
                turn.spec = nil
                turn.forcedOurTool = true
                conversationHistory = HistoryHygiene.strippingProviderSearch(
                    conversationHistory, fromTurnStart: turnHistoryStart)
                turn.historyChanged = true
                PrivacyLog.model(.providerSearch, provider: PrivacyToken(config.llmProvider.rawValue),
                                 model: PrivacyToken(config.model), detail: PrivacyToken(reason.token))
                return nil
            }
            return turn.spec.flatMap { kinds.contains($0.kind) ? $0 : nil }
        }
        let decision = ProviderSearchPolicy.decide(inputs)
        // Not declared this round is not a decision for the turn: a tool looked up later may be.
        if case .ourTool(.notDeclared) = decision { return nil }
        turn.settled = true
        PrivacyLog.model(.providerSearch, provider: PrivacyToken(config.llmProvider.rawValue),
                         model: PrivacyToken(config.model), detail: PrivacyToken(decision.token))
        guard let spec = decision.spec, kinds.contains(spec.kind) else { return nil }
        guard let origin = ProviderSearchLive.origin(for: config),
              (try? await processingConsent.authorize(url: origin, scope: .webSearch)) != nil else {
            PrivacyLog.model(.providerSearch, provider: PrivacyToken(config.llmProvider.rawValue),
                             detail: PrivacyToken(ProviderSearchPolicy.Reason.consentNotGiven.token))
            return nil
        }
        turn.spec = spec
        return spec
    }

    /// One response's search evidence: the reply's sources, the support trace, the fee, and the
    /// turn's web mark (§5); a search that failed inside the 200 starts the cool-off (§4).
    private func absorbProviderSearch(_ evidence: ProviderSearchEvidence, spec: ProviderSearchSpec,
                                      config: ModelConfig, turn: ProviderSearchTurn) {
        guard evidence.ranSearch else { return }
        if evidence.readWeb { TurnWebExposure.current?.markReadWeb() }
        addReplyWebSources(evidence.sources)
        if let suggestions = evidence.searchSuggestions { replySearchSuggestions = suggestions }
        TurnRecorder.noteProviderSearch(provider: config.llmProvider.rawValue, evidence: evidence,
                                        turnID: TurnRecorder.toolTraceID)
        if ProviderSearchRefusal.startsCoolOff(evidence.errors) {
            providerSearchMemory.noteInTurnFailure(provider: config.llmProvider, credential: turn.credential)
        }
        PrivacyLog.model(.providerSearch, provider: PrivacyToken(config.llmProvider.rawValue),
                         count: evidence.searchCount, total: evidence.sources.count,
                         detail: PrivacyToken(evidence.errors.isEmpty ? "searched" : "searchFailed"))
        if let cost = SearchFeeTable.cost(kind: spec.kind, model: config.model, searches: evidence.searchCount) {
            let tracker = usageTrackerOverride ?? UsageTracker.shared
            let fieldSessionId = FieldSessionService.shared.activeSession?.id
            let provider = config.llmProvider
            let model = config.model
            let searches = evidence.searchCount
            Task { @MainActor in
                tracker.recordSearches(provider: provider, model: model, searches: searches,
                                       costUSD: cost, fieldSessionId: fieldSessionId)
            }
        }
    }

    /// The reply's sources and Search Suggestions, handed over once to the message that keeps
    /// them; a later turn that never reaches this service (a bridge) cannot pick them up.
    func takeReplyWebAttachments() -> (sources: [WebSource], suggestions: SearchSuggestions?) {
        defer { replyWebSources = []; replySearchSuggestions = nil }
        return (replyWebSources, replySearchSuggestions)
    }

    /// Sources for the reply, de-duplicated by address, bounded like a response's.
    private func addReplyWebSources(_ sources: [WebSource]) {
        for source in sources where replyWebSources.count < ProviderSearchEvidence.maxSources
            && !replyWebSources.contains(where: { $0.url == source.url }) {
            replyWebSources.append(source)
        }
    }

    /// Run a turn; when the whole request is refused because of the provider's search (§4),
    /// remember it for this provider and account, rewind the turn's own appends (the question
    /// stays), and run it once more with our own tool. Only before any tool has run, so nothing
    /// runs twice; the retry's own errors stand.
    private func retryingWithoutProviderSearch(config: ModelConfig, turn: ProviderSearchTurn,
                                               onStreamReset: (() -> Void)?,
                                               _ run: () async throws -> String) async throws -> String {
        let dispatchedBefore = toolCallsDispatched
        do {
            return try await run()
        } catch {
            guard turn.spec != nil, !turn.forcedOurTool,
                  case LLMError.apiError(_, let status, let message, _) = error,
                  let kind = ProviderSearchRefusal.classify(status: status, message: message),
                  toolCallsDispatched == dispatchedBefore else { throw error }
            providerSearchMemory.noteRefusal(kind, provider: config.llmProvider,
                                             credential: turn.credential, model: config.model)
            TurnRecorder.noteProviderSearchRefused(provider: config.llmProvider.rawValue, kind: kind,
                                                   turnID: TurnRecorder.toolTraceID)
            PrivacyLog.model(.providerSearch, provider: PrivacyToken(config.llmProvider.rawValue),
                             model: PrivacyToken(config.model), status: status,
                             detail: PrivacyToken(ProviderSearchPolicy.Reason.refusedEarlier(kind).token))
            turn.forcedOurTool = true
            turn.spec = nil
            let rewindTo = min(max(0, turnHistoryStart + 1), conversationHistory.count)
            conversationHistory.removeSubrange(rewindTo...)
            onStreamReset?()
            return try await run()
        }
    }

    /// Whether our `web_search` is among the tools this installation can declare at all, read
    /// before the round's own list is built (the route a provider search needs is chosen first).
    private func webSearchDeclarable() -> Bool {
        ToolDeclarations.availableToolSet(registry: nativeToolRouter?.registry,
                                          mcpClient: nativeToolRouter?.mcpClient)
            .names.contains(ProviderSearchPolicy.ourToolName)
    }

    /// A chat message without the provider-search fields (`annotations`, `executed_tools`, the
    /// stashed `usage`), which are read once and never sent back in the history.
    nonisolated static func strippingSearchFields(_ message: [String: Any]) -> [String: Any] {
        var message = message
        for key in ["annotations", "executed_tools", "usage"] { message.removeValue(forKey: key) }
        return message
    }

    // MARK: - OpenAI-compatible

    /// Authorization header value for an OpenAI-compatible request, or nil for a keyless
    /// `.custom` endpoint (self-hosted Ollama/LM Studio/bridge — the save/list paths already
    /// allow an empty key for `.custom`, so the send path must too).
    nonisolated static func openAICompatibleAuthorization(provider: LLMProvider, apiKey: String) throws -> String? {
        guard apiKey.isEmpty else { return "Bearer \(apiKey)" }
        guard provider == .custom else {
            throw LLMError.missingAPIKey(provider.missingCredentialMessage)
        }
        return nil
    }

    /// The credential an OpenAI-compatible request authenticates with: the saved key, or — for an
    /// xAI model saved without one — the connected xAI account's token, which carries `api:access`
    /// and is accepted as a bearer on the public API. A typed key always wins. Empty when there is
    /// neither, which `openAICompatibleAuthorization` reports as a missing key.
    private func openAICompatibleCredential(_ config: ModelConfig) async -> String {
        guard config.llmProvider == .xai else { return config.apiKey }
        return await XAIAuth.resolveCredential(apiKey: config.apiKey, account: xaiAccount)
    }

    /// A `.custom` endpoint that 400'd on a `tools` payload (some Ollama/LM Studio builds).
    /// Remembered for the session so later turns skip tools instead of re-tripping the 400.
    /// `static nonisolated(unsafe)` because it's flipped inside the nonisolated per-turn
    /// closure; a bool flag with one realistic writer needs no stronger isolation.
    nonisolated(unsafe) private static var customEndpointRejectsTools = false

    /// Models whose provider refused reasoning alongside function tools this run (Plan GB P0,
    /// `ReasoningRejectionClassifier`). Same isolation rationale as `customEndpointRejectsTools`.
    nonisolated(unsafe) private static var reasoningToolRejections = Set<String>()

    /// Models the Responses API refused this run (Plan GC Decision 6): later turns on them route
    /// straight to Chat Completions until the app restarts. Same isolation rationale as
    /// `customEndpointRejectsTools`.
    nonisolated(unsafe) private static var responsesRouteRejections = Set<String>()

    /// Record the route of one turn (Plan GC): the endpoint token and the reason case in the
    /// privacy log, the endpoint token in the turn trace. Never text.
    static func noteRoute(_ selection: OpenAIRouteSelector.Selection,
                          provider: LLMProvider, model: String) {
        PrivacyLog.model(.routeSelected, provider: PrivacyToken(provider.rawValue),
                         model: PrivacyToken(model), detail: PrivacyToken(selection.token))
        PrivacyLog.model(.routeSelected, detail: PrivacyToken(selection.reason.rawValue))
        TurnRecorder.noteRoute(selection.token)
    }

    /// Whether a Responses failure retries the turn once on Chat Completions (Plan GC Decision 6):
    /// a 4xx that is not authentication or rate limiting — a model the endpoint does not accept,
    /// a rejected shape. 401/403/429 and 5xx behave exactly as on Chat Completions.
    nonisolated static func responsesRouteShouldFallBack(status: Int) -> Bool {
        (400...499).contains(status) && ![401, 403, 429].contains(status)
    }

    /// The Chat Completions URL for a saved base URL, through the route selector's derivation
    /// (`…/v1`, `…/v1/`, `…/chat/completions` and `…/responses` all land on `…/chat/completions`).
    /// An empty base is the API default only for the OpenAI provider: any other provider's empty
    /// base keeps the old relative path, which fails as before rather than sending that provider's
    /// key to `api.openai.com`.
    nonisolated static func chatCompletionsURLString(baseURL: String, provider: LLMProvider) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || provider == .openai else {
            return OpenAIRouteSelector.Endpoint.chatCompletions.path
        }
        return OpenAIRouteSelector.endpointURL(baseURL: trimmed, endpoint: .chatCompletions)
    }

    /// Forget what this run learned about refusals (tests only; production forgets on relaunch).
    static func resetLearnedRouteStateForTesting() {
        reasoningToolRejections.removeAll()
        responsesRouteRejections.removeAll()
        customEndpointRejectsTools = false
    }

    /// Classify and log an Anthropic response that was not a 200 (Plan IE P0). Every Anthropic
    /// call site goes through here, so a refusal always leaves a line: the status, the provider's
    /// error type, the reason it matched, which kind of credential the request carried, and the
    /// request id. The provider's message has no parameter here and reaches nothing.
    ///
    /// Returns `nil` for a 200, so the one-shot sites can call it before their own guard without
    /// first asking what the status was.
    /// - Parameter detail: which one-shot call this was; `nil` for a turn.
    @discardableResult
    nonisolated static func noteAnthropicRejection(response: URLResponse, body: Data,
                                                   request: URLRequest,
                                                   detail: String? = nil) -> ProviderRejection? {
        if let http = response as? HTTPURLResponse, http.statusCode == 200 { return nil }
        let rejection = ProviderRejection(response: response, body: body, provider: .anthropic)
        PrivacyLog.modelRejected(rejection, provider: PrivacyToken("anthropic"),
                                 auth: AnthropicAuth.credentialKind(of: request),
                                 bytes: body.count, detail: detail.map(PrivacyToken.init))
        return rejection
    }

    /// Record the effective reasoning setting of one request: a token in the turn trace (Turn
    /// details) and in the privacy log. Never text — the reason is a case name.
    static func noteReasoning(_ resolution: ReasoningPolicy.Resolution,
                              provider: LLMProvider, model: String) {
        PrivacyLog.model(.reasoningResolved, provider: PrivacyToken(provider.rawValue),
                         model: PrivacyToken(model), detail: PrivacyToken(resolution.token))
        PrivacyLog.model(.reasoningResolved, detail: PrivacyToken(resolution.reason.rawValue))
        TurnRecorder.noteReasoning(resolution.token)
    }

    /// A Responses turn held commentary-phase messages back from its reply
    /// (`ResponsesTranslator.parseOutput`): how many, and whether an answer or a tool call was
    /// left — `noAnswer` is a turn whose only text was the model's interim note, now an empty
    /// reply. Counts and a fixed token only, never the withheld words.
    static func noteWithheldCommentary(_ count: Int, answered: Bool, toolCalls: Int, provider: LLMProvider) {
        guard count > 0 else { return }
        let outcome = answered ? "answered" : (toolCalls > 0 ? "toolCall" : "noAnswer")
        PrivacyLog.model(.commentaryWithheld, provider: PrivacyToken(provider.rawValue),
                         count: count, detail: PrivacyToken(outcome))
    }

    /// Whether a provider reaching the OpenAI-compatible path can be handed a `tools` payload.
    ///
    /// This is an exhaustive switch on purpose. The bug it exists to prevent (issue 427) was a
    /// hand-written `||` chain that silently omitted `.xai` and `.minimax` when they were added
    /// to the `sendOpenAICompatible` route — the turn logged `nativeTools` while the request
    /// carried none, so voice commands never triggered a tool call on those providers. An
    /// exhaustive switch makes the next provider a compile error instead of a silent omission.
    ///
    /// The providers returning `false` here (`anthropic`, `chatgpt`, `gemini`, `geminiVertex`,
    /// `local`, `appleOnDevice`) each have their own request builder and never reach this
    /// predicate; `false` is simply the answer for "an OpenAI-style `tools` array", not a
    /// statement that they lack tool calling.
    /// Whether a Direct-mode request to `provider` carries machine-readable tool schemas (Plan GB
    /// P5): Anthropic, Gemini and the ChatGPT backend always do; Chat Completions providers do when
    /// `providerSupportsTools` says so. When they do, the prompt drops its per-tool descriptions.
    nonisolated static func toolSchemasAttached(provider: LLMProvider, customEndpointRejectsTools: Bool) -> Bool {
        switch provider {
        case .anthropic, .chatgpt, .gemini, .geminiVertex:
            return true
        case .local, .appleOnDevice:
            return false
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return providerSupportsTools(provider, customEndpointRejectsTools: customEndpointRejectsTools)
        }
    }

    nonisolated static func providerSupportsTools(_ provider: LLMProvider,
                                                  customEndpointRejectsTools: Bool) -> Bool {
        switch provider {
        case .openai, .groq, .deepseek, .mistral, .zai, .qwen, .minimax, .xai, .openrouter:
            return true
        // Custom endpoints get tools too (Gemini/vLLM/newer Ollama all speak OpenAI function
        // calling); the ones that 400 on a `tools` payload are retried once without tools and
        // remembered for the rest of the session.
        case .custom:
            return !customEndpointRejectsTools
        case .anthropic, .chatgpt, .gemini, .geminiVertex, .local, .appleOnDevice:
            return false
        }
    }

    /// Every OpenAI API request funnels through here — voice, Chat tab, photos, quick actions,
    /// Field Assist, the cloud agent, notification triage, stateless completions — so Plan GC's
    /// route selector is consulted here, before any URL is built, and not at a caller.
    private func sendOpenAICompatible(_ text: String, systemPrompt: String, volatileTail: String? = nil, config: ModelConfig, includeTools: Bool, imageData: Data?, smallContext: Bool = false, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        try enforceMedicalRemoteBoundary(config)
        let provider = config.llmProvider
        let apiKey = await openAICompatibleCredential(config)
        if apiKey.isEmpty, provider == .xai, xaiAccount.isConnected {
            // Signed in, but no usable token is left: say what the sign-in said, not "add a key".
            throw LLMError.missingAPIKey(xaiAccount.lastError ?? "xAI sign-in expired — please sign in again.")
        }
        let authorization = try Self.openAICompatibleAuthorization(provider: provider, apiKey: apiKey)
        // Plan FG P1a: a token the xAI sign-in supplied is refreshed once on a 401; every later
        // round of the tool loop sends the replacement. A typed key never rides this.
        let xaiAccountCredential: SubscriptionAuthRetry.Credential? =
            provider == .xai && XAIAuth.usesAccountSignIn(apiKey: config.apiKey) && !apiKey.isEmpty
                ? SubscriptionAuthRetry.Credential(apiKey) : nil
        if provider == .xai {
            TurnRecorder.noteCredential(xaiAccountCredential == nil ? .key : .accountSignIn)
        }

        // Plan GC: which endpoint this turn goes to, at what reasoning level, and why.
        let routeToolsAttached = includeTools
            && Self.providerSupportsTools(provider, customEndpointRejectsTools: Self.customEndpointRejectsTools)
        // Plan KZ: one turn's provider-search state, shared by whichever endpoint serves it. A
        // search that exists only on Responses (OpenAI, xAI) picks that route before the round's
        // own tool list exists, from whether our `web_search` could be declared at all; the round
        // then decides for itself, and attaches nothing if `web_search` is not declared after all.
        let searchTurn = ProviderSearchTurn(credential: apiKey)
        var routeForSearch = false
        if routeToolsAttached,
           ProviderSearchPolicy.supportedKind(
               provider: provider, model: config.model, baseURL: config.baseURL,
               learnedResponsesRejection: Self.responsesRouteRejections.contains(config.model))?
               .needsResponsesRoute == true {
            let wouldSearch = ProviderSearchPolicy.decide(ProviderSearchLive.inputs(
                for: config, credential: apiKey, webSearchDeclared: webSearchDeclarable(),
                learnedResponsesRejection: Self.responsesRouteRejections.contains(config.model),
                memory: providerSearchMemory)).spec != nil
            // The route moves only for a search that will be sent: Cloud AI Sharing's "Web
            // search" question for this host is asked here, before the route is chosen, and
            // anything but a yes keeps today's route and our tool.
            if wouldSearch, let origin = ProviderSearchLive.origin(for: config) {
                routeForSearch = (try? await processingConsent.authorize(url: origin, scope: .webSearch)) != nil
            }
        }
        var selection = config.routeSelection(
            toolsAttached: routeToolsAttached,
            learnedToolRejection: Self.reasoningToolRejections.contains(config.model),
            learnedResponsesRejection: Self.responsesRouteRejections.contains(config.model),
            providerSearch: routeForSearch)
        Self.noteRoute(selection, provider: provider, model: config.model)

        if selection.endpoint == .responses {
            // The fallback reruns the whole turn, so it is only for a turn in which no tool has
            // run yet: a 4xx on round two after `send_message` ran must not send it again
            // (review follow-up 2026-11-10, as `retryingWithoutProviderSearch` already holds).
            let dispatchedBeforeResponses = toolCallsDispatched
            do {
                return try await sendOpenAIResponses(
                    text, systemPrompt: systemPrompt, volatileTail: volatileTail, config: config,
                    includeTools: includeTools, imageData: imageData, smallContext: smallContext,
                    selection: selection, searchTurn: searchTurn,
                    onToken: onToken, onStreamReset: onStreamReset)
            } catch LLMError.apiError(_, let status, _, _)
                        where Self.responsesRouteShouldFallBack(status: status)
                            && toolCallsDispatched == dispatchedBeforeResponses {
                // Decision 6: a route decision, not a cascade hop. Remember the model for the run,
                // rewind this turn's own appends (the user message included, so the retry does not
                // add it twice — `turnHistoryStart` is its index even if `trimHistory` compacted
                // older messages), and retry once on Chat Completions at `none` with tools. The
                // retried request's own errors propagate unchanged: its 400 stays terminal.
                Self.responsesRouteRejections.insert(config.model)
                Self.reasoningToolRejections.insert(config.model)
                // Plan KZ: Chat Completions carries no OpenAI or xAI search; our tool answers.
                searchTurn.forcedOurTool = true
                let rewindTo = min(max(0, turnHistoryStart), conversationHistory.count)
                conversationHistory.removeSubrange(rewindTo...)
                PrivacyLog.model(.routeFallback, provider: PrivacyToken(provider.rawValue),
                                 model: PrivacyToken(config.model), status: status,
                                 detail: PrivacyToken(OpenAIRouteSelector.Endpoint.chatCompletions.rawValue))
                TurnRecorder.noteRoute(OpenAIRouteSelector.Endpoint.chatCompletions.rawValue)
                onStreamReset?()
                selection = config.routeSelection(toolsAttached: routeToolsAttached,
                                                  learnedToolRejection: true,
                                                  learnedResponsesRejection: true)
            }
        }
        let chatSelection = selection

        let baseURL = Self.chatCompletionsURLString(baseURL: config.baseURL, provider: provider)
        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidConfiguration("Invalid base URL: \(baseURL)")
        }

        // Add user message to history
        // Ensure we only attach images for models that are configured to accept them.
        // OpenAI-compatible endpoints vary a lot, so this is driven by the saved model config
        // with a heuristic fallback in `ModelConfig.visionEnabled`.
        let supportsVision = config.visionEnabled
        
        if let imageData = imageData, supportsVision {
            let base64String = LLMImagePreparer.prepared(imageData).base64EncodedString()
            // Custom providers proxying to Anthropic API need type:image with base64 source,
            // not OpenAI's type:image_url format.
            let isAnthropicProxy = provider == .custom && config.model.lowercased().contains("claude")
            let imageBlock: [String: Any] = isAnthropicProxy
                ? [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": base64String
                    ]
                ]
                : [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64String)"
                    ]
                ]
            let content: [[String: Any]] = [
                ["type": "text", "text": text],
                imageBlock
            ]
            conversationHistory.append(["role": "user", "content": content])
        } else if imageData != nil && !supportsVision {
            PrivacyLog.model(.imageSkipped, model: PrivacyToken(config.model))
            // Drop the image but keep the text, and inform the model
            conversationHistory.append(["role": "user", "content": text + "\n[System note: The user attempted to send an image, but the current model (\(config.model)) does not support image analysis.]"])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()
        turnHistoryStart = max(0, conversationHistory.count - 1)

        // Raised for the wrap-up request only, which then offers the model no tool to call.
        let withholding = ToolWithholding()
        let adapter = ProviderLoopAdapter(
            label: provider.displayName,
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse(provider.displayName) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let authorization {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }

                // OpenRouter requires additional headers for tracking
                if provider == .openrouter {
                    request.setValue(PublicSite.baseURL.absoluteString, forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Avenkin", forHTTPHeaderField: "X-Title")
                }

                // OpenAI format: system prompt is a message in the array. Plan GB P5: with a split
                // prompt the volatile tail follows the history, so the head and the conversation
                // stay a byte-identical, cacheable prefix from turn to turn.
                // Plan GC Decision 4: a Responses turn's raw output items (encrypted reasoning)
                // never reach a Chat Completions body — including a fallback retry's.
                let historySlice = HistoryHygiene.stripResponsesItems(
                    self.requestHistory(for: provider, smallContext: smallContext))

                // Only attach Tools if the provider reliably supports function calling.
                let providerSupportsTools = Self.providerSupportsTools(
                    provider,
                    customEndpointRejectsTools: Self.customEndpointRejectsTools
                )
                // Declared before the prompt parts: the omission note offers `brain` only when it is.
                var declared: (tools: [[String: Any]], data: Data, fromMCP: Int)?
                if includeTools && providerSupportsTools {
                    let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                    let declaring = self.roundToolFilter()   // Plan IU: nil = every tool
                    let (toolsData, mcpToolCount): (Data, Int) = await MainActor.run {
                        let mcpClient = self.nativeToolRouter?.mcpClient
                        let tools = ToolDeclarations.openAITools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: mcpClient, declaring: declaring)
                        let data = (try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])) ?? Data()
                        return (data, ToolDeclarations.mcpToolDeclarations(mcpClient: mcpClient).count)
                    }
                    declared = ((try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? [], toolsData, mcpToolCount)
                }
                // Plan KZ: OpenRouter's server tool (and Groq's, once verified) rides on Chat
                // Completions beside the function tools, with our `web_search` withheld.
                var attachedSearch: ProviderSearchSpec?
                if var current = declared,
                   let spec = await self.providerSearchSpec(
                       for: config, turn: searchTurn,
                       declaresWebSearch: ProviderSearchPolicy.declaresOurTool(current.tools),
                       kinds: [.openRouter, .groq]) {
                    attachedSearch = spec
                    current.tools = ProviderSearchPolicy.withholdingOurTool(current.tools) + [spec.toolFragment]
                    current.data = (try? JSONSerialization.data(withJSONObject: current.tools, options: [.sortedKeys])) ?? Data()
                    declared = current
                }
                let (promptForRound, tailForRound) = Self.withProviderSearchSentence(
                    attachedSearch, systemPrompt: systemPrompt, volatileTail: volatileTail)
                let system = self.requestSystemParts(
                    stable: promptForRound, volatileTail: tailForRound,
                    recallOffered: !withholding.active && APIHistoryBudget.declaresRecall(declared?.tools))
                let messages = PromptLayout.chatMessages(stable: system.stable, history: historySlice,
                                                         volatile: system.volatile)
                // Plan GB P0 / GC: the saved model's reasoning setting as the route selector resolved
                // it for Chat Completions and for whether tools ride along — the pair the
                // `gpt-6-sol` 400 depends on. Re-selected only when an earlier iteration of this
                // turn just learned a rejection (GB's one retry at `none`).
                let learnedToolRejection = Self.reasoningToolRejections.contains(config.model)
                let reasoning = learnedToolRejection
                    ? config.routeSelection(
                        toolsAttached: includeTools && providerSupportsTools,
                        learnedToolRejection: true,
                        learnedResponsesRejection: Self.responsesRouteRejections.contains(config.model)).reasoning
                    : chatSelection.reasoning
                let baseOutputCap = smallContext ? (imageData != nil ? Self.smallContextVisionMaxTokens : Config.maxTokens) : (includeTools ? Self.toolTurnMaxTokens : Config.maxTokens)
                // Plan KL P1: the shortest rung of a per-minute fit asks for a smaller answer too.
                let outputCap = PerMinuteFitScope.shortened
                    ? PerMinuteFit.shortenedOutputCap(reasoning.outputCap(base: baseOutputCap))
                    : reasoning.outputCap(base: baseOutputCap)

                var body: [String: Any] = [
                    "model": config.model,
                    "max_tokens": outputCap,
                    "messages": messages
                ]
                Self.applyQwenReasoning(to: &body, provider: provider, model: config.model,
                                        disableThinking: smallContext || (imageData != nil && supportsVision))
                reasoning.apply(to: &body)
                Self.applyGroqReasoningVisibility(to: &body, provider: provider, model: config.model)
                Self.noteReasoning(reasoning, provider: provider, model: config.model)

                if case let (tools, toolsData, mcpToolCount)? = declared {
                    body["tools"] = tools
                    // As the Anthropic path records it (Plan IE P0); the banner for a request over
                    // the per-minute allowance reads it (Plan KL P1). Counts only.
                    TurnRecorder.noteToolsSent(count: tools.count, fromMCP: mcpToolCount)
                    if withholding.active, !tools.isEmpty { body["tool_choice"] = "none" }
                    // Plan GB P5: route requests that share this prefix to the same cache. A hash of
                    // the model, the stable head and the schemas — none of the prompt's text.
                    if provider == .openai {
                        body["prompt_cache_key"] = PromptPrefixDigest.cacheKey(
                            model: config.model, stable: system.stable, tools: toolsData)
                    }
                }

                if onToken != nil {
                    body["stream"] = true
                    // Ask for a final usage chunk so the streamed path can record cost (Plan AU).
                    // Servers that don't support it ignore the field; we then simply record nothing.
                    body["stream_options"] = ["include_usage": true]
                }
                Self.applyMistralRequestShape(to: &body, provider: provider)
                Self.applyOpenAITokenLimitShape(to: &body, provider: provider, baseURL: baseURL)
                // Sorted keys: byte-identical bodies for identical content (Plan GB P5).
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                request.timeoutInterval = 60 // 60s timeout to prevent app freezing

                // Shape of the request, not its contents — and not `baseURL` either: a custom
                // endpoint URL is the wearer's own server, often on their home network.
                let messageCount = (body["messages"] as? [[String: Any]])?.count ?? 0
                // Honest even when the image came from a tool result rather than the user turn:
                // a `capture_photo` round-trip used to log `textOnly` while carrying a photo.
                let hasImage = (imageData != nil && supportsVision)
                    || ToolResultImage.historyCarriesImage(messages)
                let bodySize = request.httpBody?.count ?? 0
                PrivacyLog.model(.requestSent, provider: PrivacyToken(provider.rawValue),
                                 model: PrivacyToken(config.model), count: messageCount,
                                 bytes: bodySize,
                                 detail: PrivacyToken(hasImage ? "withImage" : "textOnly"))
                // Plan KL P1: what this request comes to, should it be refused as over the
                // account's per-minute allowance.
                self.lastChatRequestShape = (bodySize, outputCap)
                if body["tools"] == nil { TurnRecorder.noteToolsSent(count: 0, fromMCP: 0) }

                // Final-reply turns stream into the Chat tab when a streaming caller passes `onToken`;
                // the reconstructed `message` (content + tool_calls) feeds the shared tool loop unchanged.
                let rawMessage: [String: Any]
                // Retry-without-tools for `.custom` (some Ollama/LM Studio builds 400 on the
                // `tools` array): strip it, remember for the session, and re-send once.
                func retryRequestWithoutTools() throws -> URLRequest {
                    PrivacyLog.model(.toolsPayloadRejected, provider: PrivacyToken("custom"))
                    Self.customEndpointRejectsTools = true
                    body.removeValue(forKey: "tools")
                    body.removeValue(forKey: "tool_choice")
                    var retried = request
                    retried.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                    return retried
                }
                let toolsAttached = body["tools"] != nil

                @MainActor func sendOnce(_ request: URLRequest) async throws -> [String: Any] {
                if let onToken {
                    // New tool-loop iteration: clear the caller's accumulated bubble first, so an
                    // intermediate tool turn's text never concatenates with the final reply (BM P9).
                    onStreamReset?()
                    let flag = TokenDeliveryFlag()
                    func streamTurn(_ req: URLRequest) async throws -> [String: Any] {
                        try await self.withTransientSSERetries(tokenFlag: flag) {
                            try await self.streamOpenAIMessage(request: req, provider: provider, model: config.model) { token in
                                flag.mark()
                                onToken(token)
                            }
                        }
                    }
                    do {
                        return try await streamTurn(request)
                    } catch LLMError.apiError(_, 400, _, _) where provider == .custom && toolsAttached {
                        return try await streamTurn(try retryRequestWithoutTools())
                    }
                } else {
                    var (data, response) = try await self.dataSession.consentedData(for: request, scope: .conversation, consent: self.processingConsent)
                    if provider == .custom, toolsAttached,
                       (response as? HTTPURLResponse)?.statusCode == 400 {
                        (data, response) = try await self.dataSession.consentedData(for: try retryRequestWithoutTools(), scope: .conversation, consent: self.processingConsent)
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        // A provider error body quotes the request back — the prompt, and on a
                        // moderation refusal the exact phrase it objected to. Status and size only;
                        // the message still reaches the user through the thrown error.
                        let rejection = ProviderRejection(response: response, body: data, provider: provider)
                        PrivacyLog.model(.apiError, provider: PrivacyToken(provider.rawValue),
                                         status: statusCode, bytes: data.count,
                                         limit: rejection.limit, requested: rejection.requested)
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorObj = errorJson["error"] as? [String: Any],
                           let errorMsg = errorObj["message"] as? String {
                            throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode,
                                                    message: errorMsg, rejection: rejection)
                        }
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMsg = errorJson["error"] as? String {
                            throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode,
                                                    message: errorMsg, rejection: rejection)
                        }
                        throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode,
                                                message: nil, rejection: rejection)
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          var m = choices.first?["message"] as? [String: Any] else {
                        throw LLMError.invalidResponse(provider.displayName)
                    }
                    self.recordUsage(provider: provider, model: config.model, json: json)
                    // Plan KZ: the search count rides in the usage block; read with the message,
                    // then taken off it (`strippingSearchFields`).
                    if attachedSearch != nil, let usage = json["usage"] { m["usage"] = usage }
                    return m
                }
                }

                // Every send goes through the account route's one forced refresh on a 401; with no
                // account credential it is a plain send.
                @MainActor func sendSigned(_ request: URLRequest) async throws -> [String: Any] {
                    try await SubscriptionAuthRetry.send(
                        request, credential: xaiAccountCredential, provider: provider.rawValue,
                        refresh: { await self.xaiAccount.accessToken(afterRejecting: $0) },
                        sign: { token, request in
                            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        },
                        attempt: { try await sendOnce($0) })
                }

                do {
                    rawMessage = try await sendSigned(request)
                } catch LLMError.apiError(_, 400, let refusal, _)
                            where ReasoningRejectionClassifier.shouldRetry(
                                status: 400, message: refusal,
                                sentEffort: body["reasoning_effort"] as? String,
                                acceptsNone: ReasoningPolicy.chatModelAcceptsNone(
                                    provider: provider, model: config.model)) {
                    // Plan GB P0: a model missing from `ReasoningPolicy`'s table refused reasoning
                    // with tools. Retry once at `none` instead of dead-ending in the cascade, and
                    // remember the model so the rest of this run resolves to `none` up front.
                    if toolsAttached { Self.reasoningToolRejections.insert(config.model) }
                    body["reasoning_effort"] = ReasoningEffort.none.rawValue
                    PrivacyLog.model(.reasoningRetried, provider: PrivacyToken(provider.rawValue),
                                     model: PrivacyToken(config.model), attempt: 1,
                                     detail: PrivacyToken(ReasoningEffort.none.rawValue))
                    TurnRecorder.noteReasoning(ReasoningEffort.none.rawValue)
                    var retried = request
                    retried.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                    rawMessage = try await sendSigned(retried)
                }

                if let attachedSearch {
                    self.absorbProviderSearch(
                        ProviderSearchEvidence.chatMessage(rawMessage, usage: rawMessage["usage"] as? [String: Any],
                                                           provider: provider),
                        spec: attachedSearch, config: config, turn: searchTurn)
                }
                let message = Self.strippingSearchFields(rawMessage)

                var toolCalls: [ToolInvocation] = []
                if includeTools, let calls = message["tool_calls"] as? [[String: Any]] {
                    for (index, toolCall) in calls.enumerated() {
                        // Only `function.name` is truly required. Gemini's OpenAI-compatible
                        // endpoint can omit `id` and `arguments` (no-arg tools) — the old strict
                        // guard silently DROPPED such calls, so the loop finalized with an empty
                        // reply while the server had returned a perfectly good tool_call.
                        guard let function = toolCall["function"] as? [String: Any],
                              let functionName = function["name"] as? String else {
                            PrivacyLog.model(.toolCallDropped,
                                             detail: PrivacyToken("missingFunctionName"))
                            continue
                        }
                        let callId = (toolCall["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
                        let argsString = function["arguments"] as? String ?? "{}"
                        // Malformed tool arguments (Plan BF): nil `arguments` → the dispatcher returns a
                        // correctable parse error instead of running the tool with empty args.
                        let parsedArgs = try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any]
                        toolCalls.append(ToolInvocation(id: callId, name: functionName,
                                                        arguments: parsedArgs, rawArguments: argsString))
                    }
                    // One log line per turn: what was parsed vs what the server sent — the seam
                    // where a "tool_call returned but nothing executed" bug is diagnosed.
                    PrivacyLog.model(.toolCallsParsed, provider: PrivacyToken(provider.rawValue),
                                     count: toolCalls.count, total: calls.count)
                }
                let text = message["content"] as? String ?? ""
                return AssistantTurn(text: text, toolCalls: toolCalls, payload: message)
            },
            appendAssistantToolCall: { [weak self] turn in
                guard let self, let message = turn.payload as? [String: Any] else { return }
                self.conversationHistory.append(message)
            },
            appendToolResults: { [weak self] outcomes in
                guard let self else { return }
                for outcome in outcomes {
                    guard let callId = outcome.invocation.id else { continue }
                    let resultContent: String
                    switch outcome.result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }
                    // See the Anthropic path: a capture tool's photo must reach the model as an
                    // image part, not as base64 in the tool message's text (issue 427).
                    let split = ToolResultImage.extract(from: resultContent)
                    let canSeeIt = split.image != nil && config.visionEnabled
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(
                        toolName: outcome.invocation.name,
                        content: split.image != nil && !canSeeIt
                            ? ToolResultImage.textWithImageOmitted(split.text)
                            : split.text)
                    self.conversationHistory.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": framed
                    ])
                    // An OpenAI `tool` message may only carry text, so the image follows as its
                    // own user turn. `image_url` is the shape `HistoryHygiene.pruneImages`
                    // recognises, so a stale tool photo is pruned exactly like a stale user photo.
                    if canSeeIt, let image = split.image {
                        self.conversationHistory.append(["role": "user", "content": [
                            ["type": "text",
                             "text": ToolResultImage.attachmentCaption(toolName: outcome.invocation.name)],
                            ["type": "image_url",
                             "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
                        ]])
                    }
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse(provider.displayName) }
                // Gemini's OpenAI-compatible endpoint omits `content` on tool-call turns — a
                // hard guard here 400-equivalent-failed the whole conversation after a
                // successful tool run. Fall back to the accumulated turn text (may be empty).
                let message = turn.payload as? [String: Any]
                let responseText = (message?["content"] as? String) ?? turn.text
                self.conversationHistory.append(["role": "assistant", "content": responseText])
                return responseText
            }
        )

        return try await retryingWithoutProviderSearch(config: config, turn: searchTurn,
                                                        onStreamReset: onStreamReset) {
            try await runToolLoop(maxIterations: self.toolLoopIterations,
                                  adapter: self.notingStalls(adapter, asksAgainWhenSilent: true).withholdingTools(withholding),
                                  setStatus: { [weak self] in self?.toolCallStatus = $0 })
        }
    }

    // MARK: - OpenAI API over the Responses endpoint (Plan GC P2)

    /// One turn on `POST <base>/responses` with the API key: the route `OpenAIRouteSelector`
    /// picks for an explicit reasoning level with tools. Mirrors `sendChatGPT` (translator,
    /// capacity budget, streamed turn), but with the API-key path's history rules: GB's job floor,
    /// `APIHistoryBudget` and images-only-after-last-assistant choose what is sent.
    ///
    /// Reasoning is replayed across the tool round-trips of the turn: the assistant history message
    /// keeps the response's raw output items (encrypted reasoning first), `inputItems` sends them
    /// back verbatim ahead of the tool results, and they are stripped when the turn ends however it
    /// ends (Decision 4). Errors propagate; `sendOpenAICompatible` owns the Chat Completions fallback.
    private func sendOpenAIResponses(_ text: String, systemPrompt: String, volatileTail: String?,
                                     config: ModelConfig, includeTools: Bool, imageData: Data?,
                                     smallContext: Bool, selection: OpenAIRouteSelector.Selection,
                                     searchTurn: ProviderSearchTurn? = nil,
                                     onToken: ((String) -> Void)?,
                                     onStreamReset: (() -> Void)?) async throws -> String {
        try enforceMedicalRemoteBoundary(config)
        let provider = config.llmProvider
        let authorization = try Self.openAICompatibleAuthorization(provider: provider, apiKey: config.apiKey)
        // An empty base is OpenAI's own default only for OpenAI: xAI's turn goes to xAI's host
        // (Plan KZ), never with its key to `api.openai.com`.
        let responsesBase = provider == .openai || !config.baseURL.isEmpty ? config.baseURL : provider.defaultBaseURL
        let endpoint = OpenAIRouteSelector.endpointURL(baseURL: responsesBase, endpoint: .responses)
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Invalid base URL: \(endpoint)")
        }

        // The user turn, exactly as the Chat Completions path appends it (image as `image_url`,
        // the shape pruning and the translator both recognise).
        let supportsVision = config.visionEnabled
        if let imageData, supportsVision {
            let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
            conversationHistory.append(["role": "user", "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
            ]])
        } else if imageData != nil {
            PrivacyLog.model(.imageSkipped, model: PrivacyToken(config.model))
            conversationHistory.append(["role": "user", "content": text + "\n[System note: The user attempted to send an image, but the current model (\(config.model)) does not support image analysis.]"])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()
        turnHistoryStart = max(0, conversationHistory.count - 1)
        // However the turn ends — answer, yield to the wearer, loop limit, error — the opaque
        // reasoning ciphertext leaves the transcript with it.
        defer { conversationHistory = HistoryHygiene.stripResponsesItems(conversationHistory) }

        let sourceID = fieldConversationSourceID
        let recovery = ResponsesContextRecovery()
        let toolsAttached = includeTools
            && Self.providerSupportsTools(provider, customEndpointRejectsTools: Self.customEndpointRejectsTools)
        // Sorted keys, as on Chat Completions: the same bytes feed the cache key. Built per round
        // (Plan IU): a tool looked up in one round is declared in the next.
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil
        func roundTools() -> (tools: [[String: Any]]?, data: Data) {
            guard toolsAttached else { return (nil, Data()) }
            let tools = ToolDeclarations.openAITools(registry: nativeToolRouter?.registry,
                                                     includeOpenClaw: includeOpenClaw,
                                                     mcpClient: nativeToolRouter?.mcpClient,
                                                     declaring: roundToolFilter())
            let data = (try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])) ?? Data()
            return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? [], data)
        }
        let baseOutputCap = smallContext ? (imageData != nil ? Self.smallContextVisionMaxTokens : Config.maxTokens) : (includeTools ? 1024 : Config.maxTokens)
        let limit = RequestContextBudget.resolve(model: config.model, endpoint: endpoint)
        let label = provider.displayName

        // Raised for the wrap-up request only, which then offers the model no tool to call.
        let withholding = ToolWithholding()
        let adapter = ProviderLoopAdapter(
            label: label,
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse(label) }
                // A field_session start tool may have created the session during this turn.
                if let sourceID { FieldSessionService.shared.recordConversationTurn(text, sourceID: sourceID) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Bearer only, as on Chat Completions (Azure included).
                if let authorization {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
                if provider == .openrouter {
                    request.setValue(PublicSite.baseURL.absoluteString, forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("Avenkin", forHTTPHeaderField: "X-Title")
                }

                var (tools, toolsData) = roundTools()
                // Plan KZ: the provider's own `web_search` (OpenAI, xAI) as a hosted tool, with
                // ours withheld.
                var attachedSearch: ProviderSearchSpec?
                if let searchTurn,
                   let spec = await self.providerSearchSpec(
                       for: config, turn: searchTurn,
                       declaresWebSearch: ProviderSearchPolicy.declaresOurTool(tools),
                       kinds: [.openAIResponses, .xaiResponses]) {
                    attachedSearch = spec
                    tools = tools.map(ProviderSearchPolicy.withholdingOurTool)
                    toolsData = (try? JSONSerialization.data(withJSONObject: tools ?? [], options: [.sortedKeys])) ?? Data()
                }
                let (promptForRound, tailForRound) = Self.withProviderSearchSentence(
                    attachedSearch, systemPrompt: systemPrompt, volatileTail: volatileTail)
                // GB's request copy, then its prompt parts (the omission note depends on the copy).
                let historySlice = self.requestHistory(for: provider, smallContext: smallContext)
                let system = self.requestSystemParts(
                    stable: promptForRound, volatileTail: tailForRound,
                    recallOffered: !withholding.active && APIHistoryBudget.declaresRecall(tools))
                // The current user message's index within the copy: every message since it is
                // this turn's own and is protected from the capacity guard.
                let turnTail = max(0, self.conversationHistory.count - self.turnHistoryStart)
                let protectedStart = min(max(0, historySlice.count - turnTail), historySlice.count)
                // xAI's Responses take the shape without OpenAI's encrypted reasoning and cache key.
                let openAIExtras = provider != .xai
                let options = ResponsesTranslator.RequestOptions(
                    includeEncryptedReasoning: openAIExtras,
                    maxOutputTokens: selection.reasoning.outputCap(base: baseOutputCap),
                    promptCacheKey: toolsAttached && openAIExtras
                        ? PromptPrefixDigest.cacheKey(model: config.model, stable: system.stable, tools: toolsData)
                        : nil,
                    reasoning: selection.reasoning,
                    trailingDeveloperMessage: system.volatile.flatMap { $0.isEmpty ? nil : $0 },
                    hostedTools: attachedSearch.map { [$0.toolFragment] } ?? [],
                    extraInclude: attachedSearch?.responsesInclude ?? [])
                Self.noteReasoning(selection.reasoning, provider: provider, model: config.model)

                let responseJSON = try await self.budgetedResponsesTurn(
                    request: request, model: config.model, history: historySlice,
                    tools: tools, protectedStart: protectedStart, limit: limit, recovery: recovery,
                    instructions: { self.refreshedFieldInstructions(system.stable, turn: text) },
                    options: options, providerToken: provider.rawValue, providerLabel: label,
                    acceptIncomplete: true, withholdTools: withholding.active,
                    timeline: smallContext ? .off : .readingOnly,
                    onToken: onToken, onStreamReset: onStreamReset)

                let parsed = ResponsesTranslator.parseOutput(responseJSON)
                if let attachedSearch, let searchTurn {
                    self.absorbProviderSearch(ProviderSearchEvidence.responses(responseJSON, provider: provider),
                                              spec: attachedSearch, config: config, turn: searchTurn)
                }
                // Decision 9: a reply the output cap cut off before any text or tool call is named,
                // then takes the ordinary empty-completion path.
                if ResponsesTranslator.incompleteReason(responseJSON) == "max_output_tokens",
                   parsed.text.isEmpty, parsed.toolCalls.isEmpty {
                    PrivacyLog.model(.emptyCompletion, provider: PrivacyToken(provider.rawValue),
                                     model: PrivacyToken(config.model),
                                     detail: PrivacyToken("maxOutputTokens"))
                }
                PrivacyLog.model(.toolCallsParsed, provider: PrivacyToken(provider.rawValue),
                                 count: parsed.toolCalls.count)
                Self.noteWithheldCommentary(parsed.withheldCommentary, answered: !parsed.text.isEmpty,
                                            toolCalls: parsed.toolCalls.count, provider: provider)
                self.recordUsage(provider: provider, model: config.model, json: responseJSON)
                return AssistantTurn(text: parsed.text, toolCalls: parsed.toolCalls,
                                     payload: parsed.rawOutputItems)
            },
            appendAssistantToolCall: { [weak self] turn in
                guard let self else { return }
                self.conversationHistory.append(ResponsesTranslator.assistantHistoryMessage(
                    text: turn.text, toolCalls: turn.toolCalls,
                    rawOutputItems: turn.payload as? [[String: Any]] ?? []))
            },
            appendToolResults: { [weak self] outcomes in
                guard let self else { return }
                for outcome in outcomes {
                    guard let callId = outcome.invocation.id else { continue }
                    let resultContent: String
                    switch outcome.result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }
                    // Same split as the other paths: a capture tool's photo rides as its own user
                    // turn, never as base64 inside the tool message (issue 427).
                    let split = ToolResultImage.extract(from: resultContent)
                    let canSeeIt = split.image != nil && config.visionEnabled
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(
                        toolName: outcome.invocation.name,
                        content: split.image != nil && !canSeeIt
                            ? ToolResultImage.textWithImageOmitted(split.text)
                            : split.text)
                    self.conversationHistory.append(["role": "tool", "tool_call_id": callId, "content": framed])
                    if canSeeIt, let image = split.image {
                        self.conversationHistory.append(["role": "user", "content": [
                            ["type": "text",
                             "text": ToolResultImage.attachmentCaption(toolName: outcome.invocation.name)],
                            ["type": "image_url",
                             "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
                        ]])
                    }
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse(label) }
                // Lenient like the other paths — an empty final text is appended, not thrown.
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                self.conversationHistory = HistoryHygiene.stripResponsesItems(self.conversationHistory)
                return turn.text
            }
        )
        guard let searchTurn else {
            return try await runToolLoop(maxIterations: toolLoopIterations, adapter: notingStalls(adapter, asksAgainWhenSilent: true).withholdingTools(withholding),
                                         setStatus: { [weak self] in self?.toolCallStatus = $0 })
        }
        return try await retryingWithoutProviderSearch(config: config, turn: searchTurn,
                                                        onStreamReset: onStreamReset) {
            try await runToolLoop(maxIterations: self.toolLoopIterations,
                                  adapter: self.notingStalls(adapter, asksAgainWhenSilent: true).withholdingTools(withholding),
                                  setStatus: { [weak self] in self?.toolCallStatus = $0 })
        }
    }

    // MARK: - ChatGPT subscription (Responses backend, Plan BW P3)

    /// Send via the ChatGPT subscription provider: bearer OAuth token + account-id header
    /// against the Responses backend. History stays in the chat shape (`ResponsesTranslator`
    /// converts to Responses items at request time), so history hygiene, pruning, and
    /// persistence behave exactly like the OpenAI-compatible path.
    ///
    /// Internal (not private) so the forced-refresh tests can drive it through a stubbed
    /// `streamingSession` and an injected account (Plan FG P1a).
    func sendChatGPT(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?, smallContext: Bool = false, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        try enforceMedicalRemoteBoundary(config)
        let chatGPTAccount = self.chatGPTAccount
        guard let token = await chatGPTAccount.validAccessToken() else {
            throw LLMError.missingAPIKey(chatGPTAccount.isConnected
                ? (chatGPTAccount.lastError ?? "ChatGPT sign-in expired — please sign in again.")
                : "ChatGPT account not connected — sign in with ChatGPT in the model editor")
        }
        // Plan FG P1a: the token a 401 refreshes once; every later round sends the new one.
        let account = SubscriptionAuthRetry.Credential(token)
        let accountID = chatGPTAccount.accountID
        // The account catalog carries the real window of a model our table does not know. Keep
        // the stored copy fresh in the background; this turn reads what is already stored.
        ChatGPTContextCatalog.refreshIfStale(accountID: accountID)
        let endpoint = config.baseURL.isEmpty ? ChatGPTOAuth.backendResponsesURL : config.baseURL
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Invalid ChatGPT backend URL: \(endpoint)")
        }

        let protectedStart = conversationHistory.count
        let sourceID = fieldConversationSourceID
        let recovery = ResponsesContextRecovery()
        // Append the user turn in chat shape (image as image_url, so pruning recognises it).
        if let imageData, config.visionEnabled {
            let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
            conversationHistory.append(["role": "user", "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]],
            ]])
        } else if imageData != nil {
            conversationHistory.append(["role": "user", "content": text + "\n[System note: The user attempted to send an image, but vision is disabled for this model configuration.]"])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }

        // Built per round (Plan IU): a tool looked up in one round is declared in the next.
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil
        func roundTools() -> [[String: Any]]? {
            guard includeTools else { return nil }
            return ToolDeclarations.openAITools(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw,
                                                mcpClient: nativeToolRouter?.mcpClient, declaring: roundToolFilter())
        }

        // Raised for the wrap-up request only, which then offers the model no tool to call.
        let withholding = ToolWithholding()
        let adapter = ProviderLoopAdapter(
            label: "ChatGPT",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("ChatGPT") }
                // A field_session start tool may have created the session during this turn.
                if let sourceID { FieldSessionService.shared.recordConversationTurn(text, sourceID: sourceID) }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ChatGPTAuth.apply(credential: account.token, accountID: accountID, to: &request)
                let tools = roundTools()
                let limit = RequestContextBudget.resolve(
                    model: config.model, endpoint: endpoint,
                    catalogContext: ChatGPTContextCatalog.context(model: config.model, accountID: accountID))
                let reasoning = config.reasoningResolution(toolsAttached: !(tools ?? []).isEmpty)
                Self.noteReasoning(reasoning, provider: .chatgpt, model: config.model)
                let responseJSON = try await self.chatGPTWithAccountRefresh(request, account: account) { request in
                    try await self.budgetedResponsesTurn(
                        request: request, model: config.model, history: self.conversationHistory,
                        tools: tools, protectedStart: protectedStart, limit: limit, recovery: recovery,
                        instructions: { self.refreshedFieldInstructions(systemPrompt, turn: text) },
                        reasoning: reasoning, withholdTools: withholding.active, timeline: .inBudget,
                        onToken: onToken, onStreamReset: onStreamReset)
                }

                let parsed = ResponsesTranslator.parseOutput(responseJSON)
                // The parse-vs-sent diagnostic seam — where "tool_call returned but nothing
                // executed" bugs get caught.
                PrivacyLog.model(.toolCallsParsed, provider: PrivacyToken("chatgpt"),
                                 count: parsed.toolCalls.count)
                Self.noteWithheldCommentary(parsed.withheldCommentary, answered: !parsed.text.isEmpty,
                                            toolCalls: parsed.toolCalls.count, provider: .chatgpt)
                self.recordUsage(provider: .chatgpt, model: config.model, json: responseJSON)
                return AssistantTurn(text: parsed.text, toolCalls: parsed.toolCalls, payload: responseJSON)
            },
            appendAssistantToolCall: { [weak self] turn in
                guard let self else { return }
                self.conversationHistory.append(
                    ResponsesTranslator.assistantHistoryMessage(text: turn.text, toolCalls: turn.toolCalls))
            },
            appendToolResults: { [weak self] outcomes in
                guard let self else { return }
                for outcome in outcomes {
                    guard let callId = outcome.invocation.id else { continue }
                    let resultContent: String
                    switch outcome.result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }
                    // Same split as the OpenAI-compatible path — this backend speaks the chat
                    // shape too, so the image cannot ride inside the `tool` message (issue 427).
                    let split = ToolResultImage.extract(from: resultContent)
                    let canSeeIt = split.image != nil && config.visionEnabled
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(
                        toolName: outcome.invocation.name,
                        content: split.image != nil && !canSeeIt
                            ? ToolResultImage.textWithImageOmitted(split.text)
                            : split.text)
                    self.conversationHistory.append(["role": "tool", "tool_call_id": callId, "content": framed])
                    if canSeeIt, let image = split.image {
                        self.conversationHistory.append(["role": "user", "content": [
                            ["type": "text",
                             "text": ToolResultImage.attachmentCaption(toolName: outcome.invocation.name)],
                            ["type": "image_url",
                             "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]],
                        ]])
                    }
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse("ChatGPT") }
                // Lenient like the other paths — an empty final text is appended, not thrown.
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                return turn.text
            }
        )
        return try await runToolLoop(maxIterations: toolLoopIterations, adapter: notingStalls(adapter, asksAgainWhenSilent: true).withholdingTools(withholding),
                                     setStatus: { [weak self] in self?.toolCallStatus = $0 })
    }

    /// One recovery allowance shared by all requests in a user turn, not one retry per tool.
    final class ResponsesContextRecovery {
        var attempted = false
        var allowance: Int?
    }

    /// Replace the entire Field Assist contribution after every tool iteration. In particular,
    /// a change-equipment or end-session tool must not leave the previous machine in instructions.
    /// The rebuild stages no page: the turn's first build decided it, and a page a tool put up
    /// since stays on the phone (Plan KR P1).
    func refreshedFieldInstructions(_ original: String, turn: String) -> String {
        let fresh = FieldSessionService.shared.promptContext(turn: turn, stagesFigure: false)
        return Self.replacingFieldInstructions(original, fresh: fresh)
    }

    static func replacingFieldInstructions(_ original: String, fresh: String?) -> String {
        let opening = "<field_assist_context>"
        let closing = "</field_assist_context>"
        var result = original
        if let start = result.range(of: opening),
           let end = result.range(of: closing, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let fresh {
            result += "\n\n\(opening)\n\(fresh)\n\(closing)"
        }
        return result
    }

    /// Plan KK P3: what a Responses turn does about the conversation timeline.
    enum ResponsesTimeline {
        /// ChatGPT: the block goes inside the request budget, which settles note or block for the
        /// count it actually removes, and counts the block against its allowance.
        case inBudget
        /// The OpenAI API route: `APIHistoryBudget` already settled the block in the developer
        /// message; this budget only records what its capacity guard kept.
        case readingOnly
        /// A small-context copy (not a suffix of the history): no block and no reading.
        case off
    }

    /// The retry is inside performTurn, below the dispatcher. Previously completed tools and
    /// the user message therefore cannot execute/append again when the provider rejects input.
    func budgetedResponsesTurn(request template: URLRequest, model: String, history: [[String: Any]],
                               tools: [[String: Any]]?, protectedStart: Int,
                               limit: RequestContextBudget.Limit, recovery: ResponsesContextRecovery,
                               instructions: () -> String,
                               reasoning: ReasoningPolicy.Resolution? = nil,
                               options: ResponsesTranslator.RequestOptions = ResponsesTranslator.RequestOptions(),
                               providerToken: String = "chatgpt", providerLabel: String = "ChatGPT",
                               acceptIncomplete: Bool = false,
                               withholdTools: Bool = false,
                               timeline: ResponsesTimeline = .readingOnly,
                               onToken: ((String) -> Void)?, onStreamReset: (() -> Void)?) async throws -> [String: Any] {
        let recallOffered = !withholdTools && APIHistoryBudget.declaresRecall(tools)
        // `history` is the history itself (ChatGPT) or a suffix of it (the API route's copy).
        let alreadyOmitted = max(0, conversationHistory.count - history.count)
        let thread: (thread: TimelineRequestBlock.Thread?, skip: TimelineRequestBlock.Skip?) =
            timeline == .inBudget ? timelineThread(for: .chatgpt) : (nil, nil)
        while true {
            try Task.checkCancellation()
            let allowance = min(limit.inputAllowance, recovery.allowance ?? limit.inputAllowance)
            // Plan KK P3: the note or the block for each count the budget tries, so the one sent
            // follows the count it actually removed, and the block is inside the estimate.
            var settled: TimelineRequestBlock.Decision?
            let workingContext: ((Int) -> String?)? = thread.thread.map { thread in
                { removed in
                    let kept = Array(history.dropFirst(removed))
                    let reading = self.timelineReading(kept: kept, omitted: alreadyOmitted + removed)
                    let decision = TimelineRequestBlock.decide(
                        .init(thread: thread, reading: reading, omittedMessages: alreadyOmitted + removed,
                              tokenCap: TimelineRenderer.defaultTokenCap),
                        recallOffered: recallOffered, timeZone: .current)
                    settled = decision
                    return TimelineRequestBlock.workingContext(decision: decision) { partial in
                        RequestContextBudget.omissionNote(removed, recallOffered: recallOffered,
                                                          partialNotes: partial)
                    }
                }
            }
            // Plan GC: `options` (the API route's extra fields and trailing developer message) are
            // inside the estimate; the default is the subscription body, byte for byte.
            let selected = try RequestContextBudget.build(model: model, instructions: instructions(),
                history: history, tools: tools, protectedStart: protectedStart, allowance: allowance,
                options: options, recallOffered: recallOffered, workingContext: workingContext)
            // Plan KK P2: what this copy kept, which may be less than `history` held.
            if timeline != .off {
                noteTimelineReading(kept: Array(history.dropFirst(selected.omittedMessages)),
                                    omitted: alreadyOmitted + selected.omittedMessages)
            }
            if timeline == .inBudget {
                let decision: TimelineRequestBlock.Decision
                if selected.omittedMessages == 0 {
                    decision = .skipped(.nothingOmitted)
                } else if let settled, !selected.fellBackToPlainNote {
                    decision = settled
                } else {
                    decision = .skipped(selected.fellBackToPlainNote ? .noRoom : (thread.skip ?? .noThread))
                }
                recordTimeline(decision, omitted: selected.omittedMessages)
            }
            PrivacyLog.model(.contextBudget, provider: PrivacyToken(providerToken), model: PrivacyToken(model),
                             count: selected.omittedMessages, total: allowance, tokens: selected.estimate.total,
                             detail: PrivacyToken(limit.provenance))
            for (component, count) in [("instructions", selected.estimate.instructions),
                                       ("input", selected.estimate.input),
                                       ("tools", selected.estimate.tools),
                                       ("framing", selected.estimate.framing)] {
                PrivacyLog.model(.contextBudget, provider: PrivacyToken(providerToken),
                                 tokens: count, detail: PrivacyToken(component))
            }
            var request = template
            // Plan GB P0: `reasoning.effort` rides outside the budget — it is a few bytes of
            // request shape, not context.
            var body = selected.body
            reasoning?.apply(to: &body)
            // The tool loop's wrap-up: the tools stay declared beside the history's function
            // calls, and the model may not call one.
            if withholdTools, body["tools"] != nil { body["tool_choice"] = "none" }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.timeoutInterval = 120
            onStreamReset?()
            do {
                let response = try await streamResponsesTurn(request: request, onToken: onToken,
                                                             providerLabel: providerLabel,
                                                             providerToken: providerToken,
                                                             acceptIncomplete: acceptIncomplete)
                if recovery.attempted {
                    PrivacyLog.model(.contextRecovery, provider: PrivacyToken(providerToken), success: true)
                }
                return response
            } catch {
                // Do not recover after partial delivery unless the caller can replace its bubble.
                // A nil token callback means no partial output was presented.
                guard RequestContextBudget.isOverflow(error: error), !recovery.attempted,
                      onToken == nil || onStreamReset != nil else { throw error }
                recovery.attempted = true
                // Reduce relative to BOTH the model allowance and the rejected actual request.
                // Otherwise a short rejected request would be retried unchanged.
                recovery.allowance = min(allowance / 2, selected.estimate.total * 3 / 4)
                PrivacyLog.model(.contextRecovery, provider: PrivacyToken(providerToken), attempt: 1,
                                 total: recovery.allowance, success: false)
                onStreamReset?()
            }
        }
    }

    /// One streamed Responses turn: SSE events → `onToken` text deltas (nil when the caller
    /// only wants the final payload); returns the authoritative `response.completed` payload
    /// (a shed delta is cosmetic, never corrupting). Events are fed to the parser only at
    /// blank-line boundaries so a network chunk can't shear a multi-byte character or a JSON
    /// payload.
    // Internal (not private) so the streaming fixture tests can drive it through a stubbed
    // `streamingSession`.
    //
    // `providerLabel`/`providerToken` name the backend in errors and the log (Plan GC: the OpenAI
    // API route shares this). `acceptIncomplete` takes a `response.incomplete` envelope as the
    // result, so a reply the output cap cut short is named rather than lost; the subscription path
    // keeps today's behaviour (no completion → error).
    func streamResponsesTurn(request: URLRequest, onToken: ((String) -> Void)?,
                             providerLabel: String = "ChatGPT", providerToken: String = "chatgpt",
                             acceptIncomplete: Bool = false) async throws -> [String: Any] {
        let (bytes, response) = try await streamingSession.consentedBytes(for: request, scope: .conversation, consent: self.processingConsent)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 2048 { break }
            }
            let text = String(data: errorBody, encoding: .utf8) ?? ""
            let rejection = ProviderRejection(response: response, body: errorBody,
                                              provider: LLMProvider(rawValue: providerToken) ?? .openai)
            let unservedOnSubscription = providerToken == LLMProvider.chatgpt.rawValue
                && rejection.reason == .modelNotAvailable
            // The classified reason rides the log line, so a support report can say why. On the
            // subscription the same refusal means "not in the catalog" or "allowance used up";
            // whether the usage headers were at their limit tells them apart.
            let limitReading = unservedOnSubscription
                ? ChatGPTModelAvailability.limitReading(
                    headers: (response as? HTTPURLResponse)?.allHeaderFields ?? [:])
                : nil
            PrivacyLog.modelRejected(rejection, provider: PrivacyToken(providerToken),
                                     bytes: errorBody.count,
                                     detail: limitReading.map { PrivacyToken($0.rawValue) })
            // Fetch the catalog again on the next turn, which can then send a model the account
            // does serve (`ChatGPTModelAvailability`).
            if unservedOnSubscription {
                ChatGPTContextCatalog.markStale()
            }
            throw LLMError.apiError(provider: providerLabel, statusCode: status, message: text,
                                    rejection: rejection)
        }

        var parser = SSEEventParser()
        var accumulator = ResponsesTranslator.StreamAccumulator(acceptIncomplete: acceptIncomplete)
        var buffer = Data()

        func feed(_ chunk: String, flush: Bool = false) {
            var events = parser.consume(chunk)
            if flush { events += parser.flush() }
            for event in events {
                if let delta = accumulator.consume(event), let onToken {
                    TurnRecorder.markFirstToken()
                    onToken(delta)
                }
            }
        }

        for try await byte in bytes {
            buffer.append(byte)
            if byte == 0x0A, buffer.count >= 2, buffer[buffer.count - 2] == 0x0A {
                feed(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        feed(String(decoding: buffer, as: UTF8.self), flush: true)

        if let failure = accumulator.failureMessage {
            let error: [String: Any] = ["code": accumulator.failureCode ?? "", "message": failure]
            let encoded = try JSONSerialization.data(withJSONObject: error)
            throw LLMError.apiError(provider: providerLabel, statusCode: 200,
                                    message: String(decoding: encoded, as: UTF8.self),
                                    rejection: ProviderRejection(
                                        response: response, body: encoded,
                                        provider: LLMProvider(rawValue: providerToken) ?? .openai))
        }
        guard let completed = accumulator.effectiveResponse else {
            throw LLMError.invalidResponse("\(providerLabel) (stream ended without completion)")
        }
        return completed
    }

    /// One stateless Responses-backend request (BW P4): no conversation-history mutation.
    /// `responseTools`, when given, are already in the Responses shape; `forcedToolName`
    /// forces that function. Returns the raw response JSON, or nil on any failure — callers
    /// treat nil as "unavailable" and use their existing fallbacks.
    private func chatgptStatelessResponse(model: String, instructions: String, userContent: Any,
                                          responseTools: [[String: Any]]? = nil,
                                          forcedToolName: String? = nil,
                                          timeout: TimeInterval = 45) async -> [String: Any]? {
        guard !MedicalLLMRoutingPolicy.isEnforced(
            hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) else { return nil }
        guard let token = await chatGPTAccount.validAccessToken(),
              let url = URL(string: ChatGPTOAuth.backendResponsesURL) else { return nil }
        var body = ResponsesTranslator.requestBody(
            model: model, instructions: instructions,
            history: [["role": "user", "content": userContent]], tools: nil)
        if let responseTools {
            body["tools"] = responseTools
            if let forcedToolName {
                body["tool_choice"] = ["type": "function", "name": forcedToolName]
            }
        }
        let limit = RequestContextBudget.resolve(model: model, endpoint: url.absoluteString,
            catalogContext: ChatGPTContextCatalog.context(model: model, accountID: chatGPTAccount.accountID))
        guard RequestContextBudget.estimate(body).total <= limit.inputAllowance else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ChatGPTAuth.apply(credential: token, accountID: chatGPTAccount.accountID, to: &request)
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Streamed like every other backend call (it refuses `stream: false`); no token sink,
        // just the completed payload.
        return try? await chatGPTWithAccountRefresh(request, account: SubscriptionAuthRetry.Credential(token)) {
            try await self.streamResponsesTurn(request: $0, onToken: nil)
        }
    }

    /// A ChatGPT backend request with the account route's forced refresh on a 401 (Plan FG P1a):
    /// re-signed with the refreshed token and the account id it carries.
    private func chatGPTWithAccountRefresh<T>(_ request: URLRequest, account: SubscriptionAuthRetry.Credential,
                                              attempt: (URLRequest) async throws -> T) async throws -> T {
        let chatGPTAccount = self.chatGPTAccount
        return try await SubscriptionAuthRetry.send(
            request, credential: account, provider: "chatgpt",
            refresh: { await chatGPTAccount.accessToken(afterRejecting: $0) },
            sign: { token, request in
                ChatGPTAuth.apply(credential: token, accountID: chatGPTAccount.accountID, to: &request)
            },
            attempt: attempt)
    }

    /// Structured variant (BW P4): forced function call → the tool's arguments object, with the
    /// tolerant text-parse fallback (a model answering with prose JSON still yields a result).
    private func chatgptStatelessStructured(model: String, instructions: String, userContent: Any,
                                            toolName: String, toolDescription: String,
                                            jsonSchema: [String: Any]) async -> [String: Any]? {
        let tools: [[String: Any]] = [[
            "type": "function", "name": toolName,
            "description": toolDescription, "parameters": jsonSchema,
        ]]
        guard let json = await chatgptStatelessResponse(
            model: model, instructions: instructions, userContent: userContent,
            responseTools: tools, forcedToolName: toolName) else { return nil }
        let parsed = ResponsesTranslator.parseOutput(json)
        if let args = parsed.toolCalls.first(where: { $0.name == toolName })?.arguments, !args.isEmpty {
            return args
        }
        return AssessmentJSON.object(fromText: parsed.text)
    }

    // MARK: - Streaming (SSE) — Chat tab live token delivery

    /// Whether an SSE failure is worth an automatic retry (BM P9) — rate limits (429), server-side
    /// errors/overload (5xx incl. Anthropic 529), transient network drops, and interrupted streams
    /// whose reason reads as overload/truncation. Mirrors `RealtimeReconnect`'s
    /// fatal-vs-recoverable split for the chat path.
    nonisolated static func isTransientSSEError(_ error: Error) -> Bool {
        switch error {
        case LLMError.apiError(_, let status, _, _):
            return status == 429 || (500...599).contains(status)
        case LLMError.streamInterrupted(_, let reason):
            let r = reason.lowercased()
            return r.contains("overloaded") || r.contains("rate_limit")
                || r.contains("server_error") || r.contains("truncated")
        case let urlError as URLError:
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
        default:
            return false
        }
    }

    /// Reference-typed flag the streaming retry uses to know whether any token already reached the
    /// UI — a failure after visible partial text must surface as an error, never silently retry
    /// into duplicated output.
    final class TokenDeliveryFlag {
        private(set) var delivered = false
        func mark() { delivered = true }
    }

    /// Retry `attempt` on transient SSE failures with `RealtimeReconnect` backoff (BM P9). Retries
    /// only while no token has been delivered; gives up after the policy's attempts or on the
    /// first non-transient error.
    func withTransientSSERetries<T>(policy: RealtimeReconnect.Policy = .init(maxAttempts: 2, maxBackoffSeconds: 4),
                                    tokenFlag: TokenDeliveryFlag,
                                    _ attempt: () async throws -> T) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await attempt()
            } catch {
                failures += 1
                guard !tokenFlag.delivered, Self.isTransientSSEError(error),
                      let delay = policy.delay(forAttempt: failures) else { throw error }
                PrivacyLog.model(.streamRetry, attempt: failures, seconds: delay,
                                 error: SafeErrorSummary(error))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Stream an OpenAI-compatible chat-completions response, invoking `onToken` for each text
    /// delta, and return a reconstructed `message` dict (same shape as `choices[].message`) so the
    /// caller's tool loop runs identically to the buffered path. Only used when a streaming caller
    /// (the Chat tab) passes `onToken`; every other caller keeps the buffered path.
    func streamOpenAIMessage(request: URLRequest, provider: LLMProvider, model: String, onToken: @escaping (String) -> Void) async throws -> [String: Any] {
        let (bytes, response) = try await streamingSession.consentedBytes(for: request, scope: .conversation, consent: self.processingConsent)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse(provider.displayName) }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            let rejection = ProviderRejection(response: http, body: data, provider: provider)
            // Plan KL P1: a per-minute refusal's allowance and requested count are numbers, so the
            // line carries them; nothing else of the message is read.
            PrivacyLog.model(.streamError, provider: PrivacyToken(provider.rawValue),
                             status: http.statusCode, bytes: data.count,
                             limit: rejection.limit, requested: rejection.requested)
            throw LLMError.apiError(provider: provider.displayName, statusCode: http.statusCode, message: msg,
                                    rejection: rejection)
        }

        var fullContent = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]  // tool_calls accumulate by index
        // Plan KZ: a provider search's citations and executed tools, and the final usage block
        // (its search count). Where a stream puts annotations is not documented, so both the
        // delta and a closing message are read. Taken off the message by the caller.
        var annotations: [[String: Any]] = []
        var executedTools: [[String: Any]] = []
        var lastUsage: [String: Any]?
        var usage = StreamingUsageAccumulator()   // from the final include_usage chunk
        var sawDone = false
        let thinkFilter = ThinkStreamFilter(startsInThink: false)

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { sawDone = true; break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            // A mid-stream error event means the response died — the partial content must never
            // return as a successful turn (BM P9).
            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? "stream error"
                let kind = err["type"] as? String
                throw LLMError.streamInterrupted(provider: provider.displayName,
                                                 reason: kind.map { "\($0): \(msg)" } ?? msg)
            }
            usage.consumeOpenAI(obj)   // the usage chunk has empty choices, so parse it before the guard
            if let block = obj["usage"] as? [String: Any] { lastUsage = block }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            annotations += delta["annotations"] as? [[String: Any]] ?? []
            annotations += (choice["message"] as? [String: Any])?["annotations"] as? [[String: Any]] ?? []
            executedTools += delta["executed_tools"] as? [[String: Any]] ?? []

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                let visible = thinkFilter.ingest(chunk)
                guard !visible.isEmpty else { continue }
                fullContent += visible
                TurnRecorder.markFirstToken()
                onToken(visible)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let idx = call["index"] as? Int ?? 0
                    var entry = toolAcc[idx] ?? (id: "", name: "", args: "")
                    if let id = call["id"] as? String { entry.id = id }
                    if let fn = call["function"] as? [String: Any] {
                        if let n = fn["name"] as? String { entry.name = n }
                        if let a = fn["arguments"] as? String { entry.args += a }
                    }
                    toolAcc[idx] = entry
                }
            }
        }

        // Premature EOF (connection dropped before "[DONE]") is truncation, not success.
        guard sawDone else {
            throw LLMError.streamInterrupted(provider: provider.displayName,
                                             reason: "stream ended before [DONE] — response truncated")
        }

        recordUsage(provider: provider, model: model, tokensIn: usage.tokensIn, tokensOut: usage.tokensOut,
                    cacheWriteTokens: usage.cacheWriteTokens, cacheReadTokens: usage.cacheReadTokens)

        fullContent += thinkFilter.flush()
        var message: [String: Any] = ["role": "assistant", "content": fullContent]
        if !annotations.isEmpty { message["annotations"] = annotations }
        if !executedTools.isEmpty { message["executed_tools"] = executedTools }
        if !annotations.isEmpty || !executedTools.isEmpty, let lastUsage { message["usage"] = lastUsage }
        if !toolAcc.isEmpty {
            message["tool_calls"] = toolAcc.sorted { $0.key < $1.key }.map { _, v in
                ["id": v.id, "type": "function", "function": ["name": v.name, "arguments": v.args]] as [String: Any]
            }
        }
        return message
    }

    /// Stream an Anthropic Messages response, invoking `onToken` for each text delta, and return
    /// the reconstructed content blocks + stop reason so the caller's tool loop runs identically to
    /// the buffered path. Only used when a streaming caller (the Chat tab) passes `onToken`.
    func streamAnthropicContent(request: URLRequest, model: String, onToken: @escaping (String) -> Void) async throws -> (content: [[String: Any]], stopReason: String?) {
        let (bytes, response) = try await streamingSession.consentedBytes(for: request, scope: .conversation, consent: self.processingConsent)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("Anthropic") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            let rejection = Self.noteAnthropicRejection(response: http, body: data, request: request)
            throw LLMError.apiError(provider: "Anthropic", statusCode: http.statusCode, message: msg,
                                    rejection: rejection)
        }

        var blocks: [Int: [String: Any]] = [:]   // content blocks by index
        var toolJSON: [Int: String] = [:]         // accumulated input_json per tool_use block
        var stopReason: String?
        var usage = StreamingUsageAccumulator()   // input from message_start, output from message_delta
        var sawMessageStop = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            usage.consumeAnthropic(obj)

            switch type {
            case "content_block_start":
                let idx = obj["index"] as? Int ?? 0
                if let cb = obj["content_block"] as? [String: Any] {
                    blocks[idx] = cb
                    // Plan KZ: a `server_tool_use` (the provider's own web search) streams its
                    // query as `input_json_delta` like a tool call; a `web_search_tool_result`
                    // arrives whole here and has no deltas.
                    let blockType = cb["type"] as? String
                    if blockType == "tool_use" || blockType == "server_tool_use" { toolJSON[idx] = "" }
                }
            case "content_block_delta":
                let idx = obj["index"] as? Int ?? 0
                if let delta = obj["delta"] as? [String: Any], let dtype = delta["type"] as? String {
                    if dtype == "text_delta", let t = delta["text"] as? String {
                        var b = blocks[idx] ?? ["type": "text", "text": ""]
                        b["text"] = ((b["text"] as? String) ?? "") + t
                        blocks[idx] = b
                        TurnRecorder.markFirstToken()
                        onToken(t)
                    } else if dtype == "citations_delta", let citation = delta["citation"] as? [String: Any] {
                        // Plan KZ: a text block's web citations arrive one delta each, and are
                        // kept on the block so it replays exactly as received.
                        var b = blocks[idx] ?? ["type": "text", "text": ""]
                        b["citations"] = ((b["citations"] as? [[String: Any]]) ?? []) + [citation]
                        blocks[idx] = b
                    } else if dtype == "input_json_delta", let pj = delta["partial_json"] as? String {
                        toolJSON[idx, default: ""] += pj
                    } else if dtype == "thinking_delta", let t = delta["thinking"] as? String {
                        // Plan IE P2: a thinking block is only valid replayed exactly as received,
                        // so its text and its signature are assembled like any other block's.
                        // Neither reaches `onToken`: thinking is not the reply, and is not the
                        // first visible token. A `redacted_thinking` block arrives whole in
                        // `content_block_start` and has no deltas.
                        guard var b = blocks[idx] else { continue }
                        b["thinking"] = ((b["thinking"] as? String) ?? "") + t
                        blocks[idx] = b
                    } else if dtype == "signature_delta", let signature = delta["signature"] as? String {
                        guard var b = blocks[idx] else { continue }
                        b["signature"] = signature
                        blocks[idx] = b
                    }
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }
            case "message_stop":
                sawMessageStop = true
            case "error":
                // A mid-stream error event (e.g. overloaded_error) means the response died — the
                // partial content must never return as a successful turn (BM P9).
                let err = obj["error"] as? [String: Any]
                let msg = err?["message"] as? String ?? "stream error"
                let kind = err?["type"] as? String
                throw LLMError.streamInterrupted(provider: "Anthropic",
                                                 reason: kind.map { "\($0): \(msg)" } ?? msg)
            default:
                break
            }
        }

        // Premature EOF (connection dropped before message_stop) is truncation, not success.
        guard sawMessageStop else {
            throw LLMError.streamInterrupted(provider: "Anthropic",
                                             reason: "stream ended before message_stop — response truncated")
        }

        // Finalize tool_use blocks: parse the accumulated partial JSON into `input`.
        for (idx, jsonStr) in toolJSON {
            guard var b = blocks[idx] else { continue }
            // No deltas: the input that came with the block start stands.
            if jsonStr.isEmpty, b["input"] is [String: Any] { continue }
            b["input"] = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any]) ?? [:]
            blocks[idx] = b
        }

        recordUsage(provider: .anthropic, model: model, tokensIn: usage.tokensIn, tokensOut: usage.tokensOut,
                    cacheWriteTokens: usage.cacheWriteTokens, cacheReadTokens: usage.cacheReadTokens)

        let content = blocks.sorted { $0.key < $1.key }.map { $0.value }
        return (content, stopReason)
    }

    // MARK: - Google Gemini

    /// Endpoint + auth for a Gemini-family `generateContent` request (Plan AI). AI Studio
    /// (`.gemini`) keys the query string; Vertex (`.geminiVertex`) builds the project/region
    /// URL and authenticates with the Google account's Bearer token, refreshed with leeway.
    /// Credential problems throw `missingAPIKey` — per-candidate for the fallback chain, so a
    /// mid-session refresh failure moves to the next model instead of dead-airing the turn.
    func geminiRequest(for config: ModelConfig, timeout: TimeInterval? = nil) async throws -> URLRequest {
        try await geminiRequestWithAccount(for: config, timeout: timeout).request
    }

    /// `geminiRequest`, with the Google account token beside it on Vertex so a 401 can force one
    /// refresh (Plan FG P1a). AI Studio's key has nothing to refresh, so its account is nil.
    func geminiRequestWithAccount(for config: ModelConfig, timeout: TimeInterval? = nil) async throws
        -> (request: URLRequest, account: SubscriptionAuthRetry.Credential?) {
        try enforceMedicalRemoteBoundary(config)
        var request: URLRequest
        var account: SubscriptionAuthRetry.Credential?
        switch config.llmProvider {
        case .geminiVertex:
            guard let endpoint = VertexAI.endpointURL(
                projectID: Config.vertexProjectID, region: Config.vertexRegion, model: config.model) else {
                throw LLMError.invalidConfiguration("Vertex AI needs a GCP project ID and region — set them in the model editor.")
            }
            let googleAccount = self.googleAccount
            guard let token = await googleAccount.validAccessToken() else {
                throw LLMError.missingAPIKey(googleAccount.isConnected
                    ? (googleAccount.lastError ?? "Google sign-in expired — please sign in again.")
                    : "Google account not connected — sign in with Google in the model editor.")
            }
            request = URLRequest(url: endpoint)
            VertexAI.apply(accessToken: token, to: &request)
            account = SubscriptionAuthRetry.Credential(token)
        default:
            guard !config.apiKey.isEmpty else {
                throw LLMError.missingAPIKey(LLMProvider.gemini.missingCredentialMessage)
            }
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent?key=\(config.apiKey)") else {
                throw LLMError.invalidConfiguration("Invalid Gemini URL")
            }
            request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        return (request, account)
    }

    /// Per-request timeout for a Gemini `generateContent` turn. Long enough for a thinking turn
    /// with a photo; short enough that a stalled request leaves room for the retry below and the
    /// cascade after it.
    static let geminiTurnTimeout: TimeInterval = 30

    /// The wait before retrying a failed Gemini request, or nil when it should not be retried.
    /// Only a service that said it was busy — 429, or a 5xx such as 503 UNAVAILABLE — and only
    /// once: a second failure goes to the cascade. A timeout is not retried here, since it has
    /// already spent the whole allowance; nor is a cancellation.
    ///
    /// Not when the cascade has another model to go to either (`hasAlternative`): the retry gets
    /// a fresh timeout on a service that just said it was unavailable, and a tester's 503 turns
    /// each spent it in full before the hop — eight seconds to the 503, thirty more on the retry,
    /// then ChatGPT answered in six. The hop to a different provider is the better retry.
    nonisolated static func geminiRetryDelay(after error: Error, failures: Int,
                                             hasAlternative: Bool = false) -> Double? {
        guard !hasAlternative,
              case LLMError.apiError(_, let status, _, _) = error,
              status == 429 || (500...599).contains(status) else { return nil }
        return RealtimeReconnect.Policy(maxAttempts: 1, maxBackoffSeconds: 2).delay(forAttempt: failures)
    }

    /// Run a Gemini request with `geminiRetryDelay`'s single retry. The backoff sleep throws on
    /// cancellation, so a barge-in during the wait ends the turn rather than sending again.
    func withGeminiTransientRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        var failures = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await attempt()
            } catch {
                failures += 1
                guard let delay = Self.geminiRetryDelay(after: error, failures: failures,
                                                        hasAlternative: cascadeHasAlternative) else { throw error }
                PrivacyLog.model(.streamRetry, provider: PrivacyToken("gemini"), attempt: failures,
                                 seconds: delay, error: SafeErrorSummary(error))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    // Internal (not private) so the forced-refresh tests can drive a Vertex turn through a stubbed
    // `dataSession` and an injected account (Plan FG P1a).
    func sendGemini(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?, smallContext: Bool = false) async throws -> String {
        // Validate credentials up front (fast-fail before touching history); each tool-loop
        // turn re-resolves below so a token refreshed mid-loop is picked up.
        _ = try await geminiRequest(for: config)

        // Add user message to history
        if let imageData = imageData {
            let base64String = LLMImagePreparer.prepared(imageData).base64EncodedString()
            let parts: [[String: Any]] = [
                ["text": text],
                ["inlineData": ["mimeType": "image/jpeg", "data": base64String]]
            ]
            conversationHistory.append(["role": "user", "parts": parts])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()
        turnHistoryStart = max(0, conversationHistory.count - 1)
        // Plan KZ: Google Search grounding, under the same policy as every provider's search.
        let searchTurn = ProviderSearchTurn(credential: config.apiKey)

        // Raised for the wrap-up request only, which then offers the model no tool to call.
        let withholding = ToolWithholding()
        var requestsSent = 0
        let adapter = ProviderLoopAdapter(
            label: "Gemini",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("Gemini") }
                // Re-resolve endpoint + auth per turn — a Vertex token refreshed mid-tool-loop
                // is picked up; AI Studio resolves to the same keyed URL every time. A deliberate
                // timeout: the system default is 60 s, which a stalled turn spent in full.
                let prepared = try await self.geminiRequestWithAccount(for: config, timeout: Self.geminiTurnTimeout)
                var request = prepared.request
                let account = prepared.account

                // Gemini format: system instruction + contents array
                var contents: [[String: Any]] = []
                for msg in self.requestHistory(for: config.llmProvider, smallContext: smallContext) {
                    let role = msg["role"] as? String ?? "user"
                    if role == "user" || role == "model" {
                        let geminiRole = role == "assistant" ? "model" : role
                        if let textContent = msg["content"] as? String {
                            contents.append(["role": geminiRole, "parts": [["text": textContent]]])
                        } else if let parts = msg["parts"] as? [[String: Any]] {
                            contents.append(["role": geminiRole, "parts": parts])
                        }
                    } else if role == "assistant" {
                        if let textContent = msg["content"] as? String {
                            contents.append(["role": "model", "parts": [["text": textContent]]])
                        } else if let parts = msg["parts"] as? [[String: Any]] {
                            contents.append(["role": "model", "parts": parts])
                        }
                    } else if role == "function" {
                        // Function response
                        if let parts = msg["parts"] as? [[String: Any]] {
                            contents.append(["role": "user", "parts": parts])
                        }
                    }
                }

                // Plan GB P0: the saved model's level in the shape the model takes — a thinking
                // level on Gemini 3 and later, a bounded token budget on 2.x
                // (`GeminiThinkingStyle`). Never both: that is a 400.
                let reasoning = config.reasoningResolution(toolsAttached: includeTools)
                Self.noteReasoning(reasoning, provider: config.llmProvider, model: config.model)
                var body: [String: Any] = [
                    "contents": contents,
                    // CO Item 2: bounded thinking, and an allowance that covers thinking *plus*
                    // the answer. Without this, reasoning and reply compete for the same tokens
                    // and the turn can come back empty with a STOP finish. A Gemini 3 model thinks
                    // on plain turns too, so those get the same treatment.
                    "generationConfig": reasoning.geminiGenerationConfig(
                        includesTools: includeTools,
                        configuredMaxTokens: smallContext && imageData != nil ? Self.smallContextVisionMaxTokens : Config.maxTokens)
                ]

                var attachedSearch: ProviderSearchSpec?
                if includeTools {
                    let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                    let declaring = self.roundToolFilter()   // Plan IU: nil = every tool
                    let toolsData: Data = await MainActor.run {
                        let tools = ToolDeclarations.geminiRESTTools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: self.nativeToolRouter?.mcpClient, declaring: declaring)
                        return (try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])) ?? Data()
                    }
                    var tools = (try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? []
                    // Plan KZ: Google Search beside the function declarations, ours withheld. With
                    // both in one request Google documents `VALIDATED` function calling.
                    if let spec = await self.providerSearchSpec(
                        for: config, turn: searchTurn,
                        declaresWebSearch: ProviderSearchPolicy.declaresOurTool(tools), kinds: [.gemini]) {
                        attachedSearch = spec
                        tools = ProviderSearchPolicy.withholdingOurTool(tools) + [spec.toolFragment]
                    }
                    body["tools"] = tools
                    if withholding.active, !tools.isEmpty {
                        body["toolConfig"] = ["functionCallingConfig": ["mode": "NONE"]]
                    } else if attachedSearch != nil {
                        body["toolConfig"] = ["functionCallingConfig": ["mode": "VALIDATED"]]
                    }
                }
                // Plan KK P3: Gemini REST's history is budgeted by `APIHistoryBudget` like the other
                // API routes, but its single system string never carried the omission note. It now
                // carries the note and the timeline the same way, at the prompt's end; after the
                // tools, because the note offers `brain` only when it is declared.
                let declared = body["tools"] as? [[String: Any]]
                let (promptForRound, _) = Self.withProviderSearchSentence(
                    attachedSearch, systemPrompt: systemPrompt, volatileTail: nil)
                let system = self.requestSystemParts(
                    stable: promptForRound, volatileTail: nil,
                    recallOffered: !withholding.active && APIHistoryBudget.declaresRecall(declared))
                body["system_instruction"] = ["parts": [["text": system.stable]]]

                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let limits = FirstReplyPolicy.limits(
                    enabled: Config.firstReplyRaceEnabled, bodyBytes: request.httpBody?.count ?? 0,
                    thinksAtLength: FirstReplyPolicy.thinksAtLength(reasoning.wire),
                    hasNextCandidate: self.cascadeHasNextCandidate, toolsAlreadyRan: requestsSent > 0)
                requestsSent += 1

                // One bounded retry when the service says it is busy (503 UNAVAILABLE, 429, 5xx),
                // and on Vertex one forced refresh of the Google token on a 401 (Plan FG P1a).
                let googleAccount = self.googleAccount
                let data: Data = try await SubscriptionAuthRetry.send(
                    request, credential: account, provider: "google",
                    refresh: { await googleAccount.accessToken(afterRejecting: $0) },
                    sign: { token, request in VertexAI.apply(accessToken: token, to: &request) }
                ) { request in try await FirstResponseRace.run(
                    limits: limits, provider: "Gemini",
                    onHedge: { PrivacyLog.model(.firstReplyHedged, provider: PrivacyToken("gemini")) }
                ) { @MainActor [self] _ in try await self.withGeminiTransientRetry { () async throws -> Data in
                    let (payload, response) = try await self.dataSession.consentedData(for: request, scope: .conversation, consent: self.processingConsent)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let rejection = ProviderRejection(response: response, body: payload,
                                                          provider: config.llmProvider)
                        if let errorJson = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                           let errorObj = errorJson["error"] as? [String: Any],
                           let errorMsg = errorObj["message"] as? String {
                            PrivacyLog.model(.apiError, provider: PrivacyToken("gemini"),
                                             status: statusCode)
                            throw LLMError.apiError(provider: "Gemini", statusCode: statusCode,
                                                    message: errorMsg, rejection: rejection)
                        }
                        throw LLMError.apiError(provider: "Gemini", statusCode: statusCode,
                                                message: nil, rejection: rejection)
                    }
                    return payload
                } } }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    throw LLMError.invalidResponse("Gemini")
                }
                self.recordUsage(provider: .gemini, model: config.model, json: json)
                if let attachedSearch, let candidate = candidates.first {
                    self.absorbProviderSearch(ProviderSearchEvidence.gemini(candidate: candidate),
                                              spec: attachedSearch, config: config, turn: searchTurn)
                }

                var toolCalls: [ToolInvocation] = []
                if includeTools {
                    for part in parts where part["functionCall"] != nil {
                        guard let funcCall = part["functionCall"] as? [String: Any],
                              let name = funcCall["name"] as? String else { continue }
                        toolCalls.append(GeminiFunctionCalling.invocation(name: name, call: funcCall))
                    }
                }
                // Pieces of one reply: joined so a sentence ending one part never runs into the
                // next, and with the space put back where the model itself left it out — a tool
                // turn came back as "…hora exata.Tens razão".
                let text = TextSegmentJoiner.repairingGluedSentences(
                    TextSegmentJoiner.join(parts.compactMap { $0["text"] as? String }))
                return AssistantTurn(text: text, toolCalls: toolCalls, payload: parts)
            },
            appendAssistantToolCall: { [weak self] turn in
                guard let self, let parts = turn.payload as? [[String: Any]] else { return }
                self.conversationHistory.append(["role": "assistant", "parts": parts])
            },
            appendToolResults: { [weak self] outcomes in
                guard let self else { return }
                // Gemini batches all function responses into one `function` message.
                var functionResponseParts: [[String: Any]] = []
                // Images ride in a user turn after it — a functionResponse carries JSON, not parts.
                var attachedImages: [(name: String, data: Data)] = []
                for outcome in outcomes {
                    let name = outcome.invocation.name
                    let resultContent: [String: Any]
                    switch outcome.result {
                    case .success(let text):
                        // A capture tool's photo becomes an `inlineData` part below, never base64
                        // text in the function response (issue 427).
                        let split = ToolResultImage.extract(from: text)
                        let canSeeIt = split.image != nil && config.visionEnabled
                        if canSeeIt, let image = split.image {
                            attachedImages.append((name: name, data: image))
                        }
                        // Frame untrusted external content as data, not instructions.
                        resultContent = ["result": self.wrapToolResultForModel(
                            toolName: name,
                            content: split.image != nil && !canSeeIt
                                ? ToolResultImage.textWithImageOmitted(split.text)
                                : split.text)]
                    case .failure(let error):
                        resultContent = ["error": error]
                    }
                    functionResponseParts.append(GeminiFunctionCalling.responsePart(
                        for: outcome.invocation, response: resultContent))
                }
                self.conversationHistory.append(["role": "function", "parts": functionResponseParts])
                for attached in attachedImages {
                    // `inlineData` is both Gemini's user-image shape and what
                    // `HistoryHygiene.pruneImages` strips, so these prune like user photos.
                    self.conversationHistory.append(["role": "user", "parts": [
                        ["text": ToolResultImage.attachmentCaption(toolName: attached.name)],
                        ["inlineData": ["mimeType": "image/jpeg",
                                        "data": attached.data.base64EncodedString()]],
                    ]])
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse("Gemini") }
                guard !turn.text.isEmpty else {
                    // CO Item 2: an empty completion is classified `retryOtherModel`, so the
                    // cascade silently rescues the turn and the user never notices. Good
                    // behaviour, terrible observability — a systematic defect (an unbounded
                    // thinking pass eating the whole allowance) would read as ordinary model
                    // churn. Mark it distinctly on the way past so it can be found in a log.
                    PrivacyLog.model(.emptyCompletion, provider: PrivacyToken("gemini"),
                                     detail: PrivacyToken(includeTools ? "tool" : "plain"))
                    throw LLMError.invalidResponse("Gemini")
                }
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                return turn.text
            }
        )

        return try await retryingWithoutProviderSearch(config: config, turn: searchTurn, onStreamReset: nil) {
            try await runToolLoop(maxIterations: self.toolLoopIterations,
                                  adapter: self.notingStalls(adapter).withholdingTools(withholding),
                                  setStatus: { [weak self] in self?.toolCallStatus = $0 })
        }
    }

    /// The adapter with the loop's one re-ask wired in: a note from the app goes into history as a
    /// user turn. Every cloud path here keeps a plain user turn as `["role": "user", "content":
    /// text]` — the Gemini and Responses senders translate that shape on the wire — so one
    /// closure serves all five. `asksAgainWhenSilent` is for the three paths whose `finalize` keeps
    /// an empty reply; Anthropic and Gemini throw on one, which is how the cascade hops.
    private func notingStalls(_ adapter: ProviderLoopAdapter, asksAgainWhenSilent: Bool = false) -> ProviderLoopAdapter {
        var noting = adapter
        noting.asksAgainWhenSilent = asksAgainWhenSilent
        noting.appendUserNote = { [weak self] text in
            self?.conversationHistory.append(["role": "user", "content": text])
        }
        // Plan KR P5: a read is not something done, so the turn's own closing words leave it out.
        noting.readsOnly = { [weak self] call in
            self?.callEffect(ofTool: call.name, args: call.arguments ?? [:]) == .readOnly
        }
        return noting
    }

    // MARK: - Local (On-Device MLX)

    // MARK: - Apple Foundation Models (On-Device)

    private func sendAppleOnDevice(_ text: String, systemPrompt: String,
                                   includeTools: Bool, carryHistory: Bool) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw LLMError.missingAPIKey("Apple Intelligence requires iOS 26+")
        }
        return try await sendAppleOnDeviceImpl(text, systemPrompt: systemPrompt,
                                               includeTools: includeTools, carryHistory: carryHistory)
        #else
        throw LLMError.missingAPIKey("Apple Foundation Models requires iOS 26+")
        #endif
    }

    #if canImport(FoundationModels)
    /// One turn on Apple's on-device model (Plan JD P0).
    ///
    /// The session is **built for the turn**: fresh instructions (the lean prompt changes every
    /// turn — date, location, memory), the tool adapters for the names `AppleOnDeviceToolSet`
    /// chose, and the last few turns of the app's own `conversationHistory` as the transcript. It
    /// is not kept between turns: the app's history is the one record a cleared or reloaded
    /// conversation already keeps consistent, and the first design — one session for the life of
    /// the preset — answered every turn with the instructions of the first.
    ///
    /// Tools run inside `respond(to:)`: the framework calls each adapter, which hops to the main
    /// actor and `NativeToolRouter.executeRoot`, and folds the result into the same turn. A window
    /// the model reports as full is retried with a shorter carry, then none.
    @available(iOS 26.0, *)
    private func sendAppleOnDeviceImpl(_ text: String, systemPrompt: String,
                                       includeTools: Bool, carryHistory: Bool) async throws -> String {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            switch availability {
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    // The keyless first-run default can land here, so name the way out.
                    throw LLMError.missingAPIKey("Device does not support Apple Intelligence — add an API key in Settings → Assistant → AI Models to use a cloud model")
                case .appleIntelligenceNotEnabled:
                    throw LLMError.missingAPIKey("Enable Apple Intelligence in iPhone Settings > Apple Intelligence & Siri")
                case .modelNotReady:
                    throw LLMError.missingAPIKey("Apple Intelligence model is still downloading, try again later")
                @unknown default:
                    throw LLMError.missingAPIKey("Apple Intelligence unavailable")
                }
            default:
                throw LLMError.missingAPIKey("Apple Intelligence unavailable")
            }
        }

        let tools = includeTools ? appleTools() : []
        let history = carryHistory
            ? recentTupleHistory(AppleSessionPolicy.carriedEntryLimit, stripToolMarkup: false)
                .filter { !$0.content.isEmpty }
            : []
        // A tool runs once per turn however many sessions the turn takes (`AppleToolResultCache`).
        appleToolResults.clear()
        defer {
            if appleToolResults.replays > 0 {
                PrivacyLog.model(.toolResultReplayed, provider: PrivacyToken("appleOnDevice"),
                                 count: appleToolResults.replays)
            }
            appleToolResults.clear()
        }

        // Respond, shrinking the carried history when the window is full. The retry rebuilds the
        // session — a session that has thrown for size holds the oversize transcript. The carry
        // starts at what the history actually holds, so a new conversation never "retries".
        let (session, firstAnswer) = try await appleRespond(
            to: text, instructions: systemPrompt, tools: tools, history: history,
            carry: AppleSessionPolicy.initialCarry(
                requested: carryHistory ? AppleSessionPolicy.carriedEntryLimit : 0, available: history.count))
        var answer = firstAnswer

        // Uncertainty gate (Plan BI): with `web_search` now a real tool on this path, the re-ask is
        // the backstop for an answer the model hedged without searching. The session keeps the
        // turn's transcript, so its rewrite is context-aware; the shared history feeds the
        // grounding prompt for cross-answer reconciliation.
        if !MedicalLLMRoutingPolicy.isEnforced(
               hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly),
           Config.localWebSearchFallbackEnabled,
           !offlineHandoffTurn,
           UncertaintyDetector.assess(question: text, answer: answer).shouldSearch {
            let recent = recentTupleHistory(6, stripToolMarkup: false)
            let reaskSession = session
            answer = await UncertaintyReask.answer(
                question: text,
                originalAnswer: answer,
                vaultOnly: VaultOnlyPolicy.jobIsSealed,
                history: recent,
                search: { query in try await WebSearchTool().execute(args: ["query": query]) },
                rewriteQuery: { q in
                    try await reaskSession.respond(to: "Rewrite this follow-up as ONE self-contained web search query, using our conversation for context. If it already stands alone, output it unchanged. Output only the query, nothing else: \(q)").content
                },
                regenerate: { grounding in try await reaskSession.respond(to: grounding).content }
            )
        }

        if carryHistory {
            // The turn joins the app's history — the record the next session is built from, and
            // what a follow-up ("what about tomorrow?") reads. The first design never wrote here,
            // so the on-device conversation existed only inside a session nothing else could see.
            conversationHistory.append(["role": "user", "content": text])
            conversationHistory.append(["role": "assistant", "content": answer])
            trimHistory()
        }
        return answer
    }

    /// One `respond(to:)`, with the session built for it. A window the model reports as full is
    /// retried with the next shorter carry until there is nothing left to drop; with nothing
    /// carried it fails at once, as `LLMError.contextOverflow` — the instructions and tools alone
    /// did not fit, which no retry can fix. A rebuilt session's tool calls replay the first run's
    /// results (`appleToolResults`) rather than running again.
    @available(iOS 26.0, *)
    private func appleRespond(to text: String, instructions: String, tools: [any Tool],
                              history: [(role: String, content: String)],
                              carry initialCarry: Int) async throws -> (LanguageModelSession, String) {
        var carry = initialCarry
        while true {
            let session = LanguageModelSession(
                tools: tools,
                transcript: AppleToolBridge.transcript(instructions: instructions, tools: tools,
                                                       history: history, carry: carry))
            do {
                let answer = try await session.respond(to: text).content
                return (session, answer)
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                guard let shorter = AppleSessionPolicy.carryAfterOverflow(carry, available: history.count) else {
                    PrivacyLog.model(.contextRecovery, provider: PrivacyToken("appleOnDevice"),
                                     count: 0, total: carry, success: false)
                    throw LLMError.contextOverflow(provider: "Apple Intelligence",
                                                   toolsRan: !appleToolResults.isEmpty)
                }
                PrivacyLog.model(.contextRecovery, provider: PrivacyToken("appleOnDevice"),
                                 count: shorter, total: carry)
                carry = shorter
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LanguageModelSession.GenerationError {
                throw Self.appleGenerationFailure(error)
            } catch let error as LanguageModelSession.ToolCallError {
                // An adapter never throws, so this is the framework's own tool plumbing.
                PrivacyLog.model(.requestFailed, provider: PrivacyToken("appleOnDevice"),
                                 detail: PrivacyToken("toolCall"), error: SafeErrorSummary(error.underlyingError))
                throw LLMError.invalidResponse("Apple Intelligence could not run a tool: \(error.underlyingError.localizedDescription)")
            }
        }
    }

    /// The Apple adapters for this turn's tool names, rebuilt only when the names change. A tool
    /// whose schema the framework rejects is dropped and logged, never fatal.
    @available(iOS 26.0, *)
    private func appleTools() -> [any Tool] {
        guard let router = nativeToolRouter else { return [] }
        let registry = router.registry
        // This path picks from the registry itself, so the seal is applied here (Plan KE).
        let names = AppleOnDeviceToolSet.priorityNames(
            registered: VaultOnlyPolicy.jobIsSealed ? VaultOnlyPolicy.unsealed(registry.toolNames) : registry.toolNames,
            fieldAssistActive: Config.fieldAssistActive,
            offlineHandoff: offlineHandoffTurn,
            libraryHasManuals: PersonalManualLibrary.permitted && !PersonalManualLibrary.shared.manuals.isEmpty)
        if let cache = appleToolCache, cache.names == names { return cache.tools }

        let dispatch: @Sendable (String, String) async -> String = { [weak self] name, json in
            await self?.runAppleTool(name: name, argumentsJSON: json)
                ?? "Error: the assistant is no longer available"
        }
        var candidates: [(AppleOnDeviceToolSet.Candidate, NativeToolAdapter)] = []
        for name in names {
            guard let tool = registry.tool(named: name) else { continue }
            do {
                let adapter = try AppleToolBridge.adapter(
                    name: name, description: tool.description,
                    parameters: tool.parametersSchema, dispatch: dispatch)
                let root = AppleToolSchema.root(toolName: name, parameters: tool.parametersSchema)
                let tokens = AppleToolSchema.estimatedTokens(
                    name: name, description: adapter.description, root: root)
                candidates.append((.init(name: name, estimatedTokens: tokens), adapter))
            } catch {
                PrivacyLog.model(.toolsPayloadRejected, provider: PrivacyToken("appleOnDevice"),
                                 detail: PrivacyToken(name), error: SafeErrorSummary(error))
            }
        }
        let kept = Set(AppleOnDeviceToolSet.fit(candidates.map(\.0)).map(\.name))
        let tools: [any Tool] = candidates.filter { kept.contains($0.0.name) }.map(\.1)
        PrivacyLog.model(.toolProfileApplied, provider: PrivacyToken("appleOnDevice"),
                         count: tools.count, total: names.count)
        appleToolCache = (names, tools)
        return tools
    }

    /// One tool call from the on-device model, through the same authority as every other caller.
    /// Returns text in every case: the result, or the reason there is none, for the model to relay.
    private func runAppleTool(name: String, argumentsJSON: String) async -> String {
        toolCallsDispatched += 1   // Plan KL P1, as the shared dispatcher counts
        guard let router = nativeToolRouter else { return "Error: tools are not available" }
        // A session rebuilt after a full window asks again for what this turn already ran; the
        // first result answers it (`AppleToolResultCache`).
        return await appleToolResults.resolve(name: name, argumentsJSON: argumentsJSON) { [weak self] in
            let args = AppleToolArguments.dictionary(fromJSON: argumentsJSON)
            PrivacyLog.localModel(.toolCall, model: PrivacyToken("appleOnDevice"), tool: PrivacyToken(name))
            // Plan KL P2: only a call that runs is entered; a replay above ran nothing new.
            let ledgerID = self?.ledgerDispatched(name, args: args,
                                                  arguments: AttemptToolLedger.canonicalArguments(json: argumentsJSON))
            self?.toolCallStatus = .executing(name)
            let startedAt = Date()
            let (outcome, completion) = await ActionCompletionReport.collect {
                await router.executeRoot(name: name, args: args)
            }
            TurnRecorder.addToolTime(since: startedAt)
            self?.toolCallStatus = .idle
            if let ledgerID {
                self?.turnToolLedger.finished(ledgerID, outcome: outcome, completion: completion)
            }
            switch outcome {
            case .completed(let text): return text
            case .outcomeUnknown(_, let message): return message
            case .rejected(let reason), .failedBeforeExecution(let reason): return "Error: \(reason)"
            }
        }
    }

    /// The app's error for a generation the framework refused. Each case names its own way out,
    /// because the generic line ("something went wrong") was what the wearer heard before.
    @available(iOS 26.0, *)
    nonisolated static func appleGenerationFailure(_ error: LanguageModelSession.GenerationError) -> LLMError {
        switch error {
        case .guardrailViolation, .refusal:
            return .modelDeclined(provider: "Apple Intelligence")
        case .exceededContextWindowSize:
            return .contextOverflow(provider: "Apple Intelligence", toolsRan: false)
        case .assetsUnavailable:
            return .missingAPIKey("Apple Intelligence isn't available right now — try again in a moment, or add an API key in Settings → Assistant → AI Models")
        case .unsupportedLanguageOrLocale:
            return .invalidConfiguration("Apple Intelligence doesn't support this language yet — choose a cloud model in Settings → Assistant → AI Models")
        case .rateLimited, .concurrentRequests:
            return .invalidResponse("Apple Intelligence is busy — try again in a moment")
        case .unsupportedGuide, .decodingFailure:
            return .invalidResponse("Apple Intelligence returned something the app could not read")
        @unknown default:
            return .invalidResponse("Apple Intelligence error: \(error.localizedDescription)")
        }
    }
    #endif

    /// The reduced tool set a local model is offered — only simple, reliable, self-contained tools
    /// (each resolves its own inputs, e.g. `get_weather`/`where_am_i` read LocationService directly,
    /// so the 2B model never has to supply coordinates it doesn't have).
    nonisolated static let localSafeTools: Set<String> = [
        "get_weather", "get_datetime", "calculate", "set_timer",
        "flashlight", "brightness", "calendar", "reminder",
        "set_alarm", "step_count", "device_info", "music_control",
        "where_am_i", "health_summary",
        // Explicit scene capture can save on-device OCR even without a vision model.
        "remember_scene", "memory_search",
        // Plan IW P1: reads the phone's own trail, goals and schedule; nothing to supply.
        "activity"
    ]

    /// Record an exchange the LLM didn't produce — tier-0 direct tool answers — so
    /// follow-up turns can see it. Without this, "what about tomorrow?" after a direct
    /// weather answer reached the model with no forecast anywhere in its history (the
    /// direct path bypasses the LLM entirely; it only wrote to the UI transcript).
    func recordExternalExchange(user: String, assistant: String) {
        cancelOffConversationRun()
        conversationHistory.append(["role": "user", "content": user])
        conversationHistory.append(["role": "assistant", "content": assistant])
        trimHistory()
    }

    /// "Tuesday, 15 July 2026, 6:41 pm (Pacific/Auckland)" — injected into every system
    /// prompt. Pure and injectable for tests.
    nonisolated static func currentDateTimeLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
        return "\(formatter.string(from: now)) (\(timeZone.identifier))"
    }

    /// Parse the local model's `<tool_call>` markup.
    ///
    /// FC P1: now a thin reading of `LocalOutputPolicy`, so there is exactly one parser. The
    /// regex this used to carry accepted only a complete frame and said nothing about the rest of
    /// the output, which is how broken protocol reached the speaker while this returned nil.
    nonisolated static func parseLocalToolCall(_ response: String) -> (name: String, args: [String: Any])? {
        guard let invocation = LocalOutputPolicy.classify(response).invocation else { return nil }
        return (invocation.name, invocation.arguments)
    }

    /// True when the reply narrates an intention to fetch/check something without any
    /// tool markup — the shape a small model produces instead of acting.
    /// The last `n` history entries as (role, content) tuples — the shape the local paths and
    /// UncertaintyReask consume. Optionally strips `<tool_call>` markup (local path keeps its
    /// context clean; the Apple path's transcript never contains markup).
    private func recentTupleHistory(_ n: Int, stripToolMarkup: Bool) -> [(role: String, content: String)] {
        conversationHistory.suffix(n).compactMap { turn in
            guard let role = turn["role"] as? String, var content = turn["content"] as? String else { return nil }
            if stripToolMarkup {
                if role == "assistant" {
                    // FC P1: bounded sanitation of what the local path feeds back. An older
                    // assistant turn that ended in a half-written frame or a bare call object is
                    // removed from the model's context entirely, so the model is never shown its
                    // own broken protocol as an example to copy. This is the in-memory tuple view
                    // only — the saved conversation is untouched — and a turn that cleans to
                    // nothing is dropped by the `isEmpty` check below.
                    content = LocalOutputPolicy.speakableText(content)
                } else {
                    // A user turn keeps the narrower complete-frame strip it has always had: a
                    // person may legitimately quote the protocol, and rewriting what they said is
                    // not this cleanup's business.
                    content = content
                        .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return content.isEmpty ? nil : (role: role, content: content)
        }
    }

    nonisolated static func announcesToolIntent(_ response: String) -> Bool {
        let lowered = response.lowercased()
        guard !lowered.contains("<tool_call>") else { return false }
        // A promise-instead-of-action reply is SHORT (a sentence or two). A long answer that
        // merely contains "searching for"/"let me check" mid-prose is an answer, not a stall —
        // without this gate the never-speak-a-promise net could discard valid replies.
        guard lowered.count < 280 else { return false }
        let intentPhrases = [
            "looking up", "look that up", "look it up", "let me check", "i'll check",
            "i will check", "checking the", "let me get", "i'll get", "i'm getting",
            "fetching", "one moment", "just a moment", "i'm looking",
            // Search-flavoured announcements (live-traced: "I will now search for popular
            // tourist destinations in Samoa for you" — then silence). Anchored to first-person
            // intent so an answer that merely mentions searching doesn't match.
            "i will now search", "i will search", "i'll search", "let me search",
            "i'm searching", "searching for", "i should have used a tool",
            "i will use a tool", "using a tool to",
        ]
        return intentPhrases.contains { lowered.contains($0) }
    }

    /// True when the reply asks the user to supply their location — the model has
    /// where_am_i available and must never ask (live-traced: "If you tell me your current
    /// location, I can check the forecast for you").
    nonisolated static func asksUserForLocation(_ response: String) -> Bool {
        let lowered = response.lowercased()
        guard !lowered.contains("<tool_call>") else { return false }
        let askPhrases = [
            "your location", "your current location", "where you are",
            "what city", "which city", "your city", "tell me where",
            "let me know where", "share your location",
        ]
        return askPhrases.contains { lowered.contains($0) }
    }

    /// The reduced tool block appended to the lean on-device prompt. Extracted (and pure)
    /// so the location nudge is testable: without it, a small model that has no USER
    /// LOCATION line answers "I can't find your location" instead of calling `where_am_i`.
    nonisolated static func localToolInstructions(toolNames: [String]) -> String {
        guard !toolNames.isEmpty else { return "" }
        var block = """

        \nTOOLS (use sparingly, only when the user clearly needs one):
        Output exactly: <tool_call>{"name": "tool_name", "arguments": {"key": "value"}}</tool_call>
        Available: \(toolNames.joined(separator: ", "))
        Only use a tool if the user explicitly asks for that action. Otherwise just answer directly.
        """
        if toolNames.contains("where_am_i") {
            block += "\nIf you need the user's location and it isn't given above, call where_am_i — never say you lack location access and never ask the user where they are."
        }
        if toolNames.contains("calendar") {
            // Live-traced: without the argument schema the model only ever got the default
            // ("today"), asked the user for dates it couldn't use, then denied having access.
            block += "\ncalendar arguments: {\"action\": \"today\" | \"tomorrow\" | \"next\" | \"upcoming\"} — pick the one matching the day asked about. You DO have the user's calendar through this tool; never claim you lack calendar access and never ask for a date when one of these actions fits."
        }
        return block
    }

    /// The installation record the coordinator needs for an MLX model, resolved from the bundled
    /// catalog without touching disk (Plan DZ P0).
    ///
    /// Built rather than read back from `LocalModelRepository` on purpose: a turn must not become
    /// dependent on the migration having run, and a saved model id that is not in the catalog —
    /// a retired entry, or one the user typed — resolves to a compatibility descriptor so no
    /// configuration can be made unusable by this seam. Storage is `.legacyHubSnapshot`, which is
    /// where MLX files actually live and where PR1 leaves them.
    /// The compatibility installation for a model with no record — a hub snapshot discovered on
    /// disk, or an id someone typed. One definition, shared with the selection resolver, so the
    /// turn path and the model manager cannot synthesize two different installations for the same
    /// id.
    nonisolated static func mlxInstallation(forModelID modelID: String) -> InstalledLocalModel {
        LocalModelSelection.compatibilityInstallation(for: LocalModelID(modelID))
    }

    // Unlike the cloud providers, the on-device path is deliberately NOT on the shared `runToolLoop`
    // driver (Plan BG P3). On-device models don't expose a structured tool-use API — they emit
    // `<tool_call>` markup — so this path is single-shot with a reduced tool set and one optional
    // re-generation, not an iterate-until-done loop. Routing it through the iterative driver would
    // change its behaviour, which the refactor explicitly avoids.
    private func sendLocal(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data? = nil, onToken: ((String) -> Void)? = nil) async throws -> String {
        // The on-device agent path reaches this without going through `sendMessage`, so the turn
        // scope is opened here too — a conversation reset must not land between this turn's
        // generation and the history insertion at the end of it.
        beginTurnScope()
        defer { endTurnScope() }

        guard let localService = localLLMService else {
            throw LLMError.missingAPIKey("Local LLM service not initialized")
        }

        // Load the configured model (no auto-swap — user picks one model). With the DZ seam on,
        // the same load goes through the coordinator, which owns residency across runtimes; with
        // it off this is the call it has always been.
        // The selected model is a stable id whose runtime comes from its installation record; the
        // legacy `config.model` string is the fallback for a device whose selection migration has
        // not run. For every MLX model the two are the same string by construction, so this path is
        // unchanged for everyone who has one selected.
        let selection = LocalModelSelection.store()
        let overrides = localTurnOverridesForTesting
        let selectedID = overrides?.selectedID ?? selection.selectedID() ?? LocalModelID(config.model)
        let installation = overrides?.installation ?? LocalModelSelection.installation(for: selectedID)
        let isGGUF = installation.runtime == .llamaCpp

        // A GGUF model has no direct route: `LocalLLMService` is the MLX runtime. The coordinator
        // is therefore required for it, whatever the seam flag says — that flag is about which
        // route *MLX* takes, not about whether a second runtime exists.
        let useCoordinator = Config.localRuntimeCoordinatorEnabled || isGGUF
        if useCoordinator {
            try await coordinator(for: localService).load(
                installation,
                configuration: LocalLoadConfiguration(
                    contextLength: installation.descriptor.contextLength > 0
                        ? installation.descriptor.contextLength
                        : LocalModelBudget.contextWindow(for: selectedID.rawValue)))
        } else if !localService.isModelLoaded || localService.loadedModelId != config.model {
            try await localService.loadModel(config.model)
        }

        // Build tool instructions — use minimal set for local models
        var fullPrompt = systemPrompt
        if includeTools, let router = nativeToolRouter {
            let toolNames = Self.localToolNames(registered: VaultOnlyPolicy.jobIsSealed ? VaultOnlyPolicy.unsealed(router.registry.toolNames) : router.registry.toolNames,
                                               offlineHandoff: offlineHandoffTurn,
                                               libraryHasManuals: PersonalManualLibrary.permitted && !PersonalManualLibrary.shared.manuals.isEmpty)
            fullPrompt += Self.localToolInstructions(toolNames: toolNames)
            // Plan IU: the on-device path is outside the setting — it has always carried its own
            // reduced list, names only, smaller than any core set. Logged so the report says so.
            PrivacyLog.model(.toolExposure, provider: PrivacyToken(config.llmProvider.rawValue),
                             model: PrivacyToken(config.model), count: toolNames.count,
                             total: router.registry.toolNames.count,
                             detail: PrivacyToken(ToolExposure.core.rawValue),
                             reason: PrivacyToken(ToolExposureReason.onDevice.rawValue))
        }

        // Build history — last 3 exchanges for local models (context is precious; the
        // LocalModelBudget cap still guards the ceiling). Was 2 — too short for a
        // follow-up that references the answer before last.
        //
        // Plan GE: a turn the handoff put on the phone carries the conversation across instead —
        // the newest turns that fit this model's budget, behind the compactor's summary when one
        // exists — so the on-device model picks up where the cloud left off.
        let history: [(role: String, content: String)]
        if offlineHandoffTurn {
            let budget = LocalModelBudget.promptBudget(for: selectedID.rawValue)
                - HandoffTranscriptBridge.estimatedTokens(fullPrompt)
                - HandoffTranscriptBridge.estimatedTokens(text)
            history = HandoffTranscriptBridge.outboundWindow(
                history: recentTupleHistory(conversationHistory.count, stripToolMarkup: true),
                budgetTokens: budget)
        } else {
            history = recentTupleHistory(6, stripToolMarkup: true)
        }

        // Add user message to history
        conversationHistory.append(["role": "user", "content": text])
        trimHistory()

        // One generation function for the whole turn, chosen once (Plan FC P1). Every later pass —
        // the corrective re-generation, the tool-result re-generation, the web re-ask's rewrite and
        // regeneration — goes through it, so a turn that loaded its model through the coordinator
        // (or a GGUF model, which has no other route) can no longer regenerate against the MLX
        // service where nothing is resident. That is what those passes used to do: one wrapped in
        // `try?`, so the correction silently never happened, the other falling back to speaking the
        // raw tool result.
        let inferenceCoordinator = useCoordinator ? coordinator(for: localService) : nil
        let maxOutputTokens = LocalModelBudget.generationReserve(for: selectedID.rawValue)
        let prompt = fullPrompt
        //
        // `systemOverride` exists for one caller: the re-ask's query rewrite, which has always run
        // under its own one-line system prompt rather than the turn's. Routing it through the same
        // function is what keeps it on the turn's runtime.
        let generate: (_ message: String,
                       _ turnHistory: [(role: String, content: String)],
                       _ image: Data?,
                       _ preview: ((String) -> Void)?,
                       _ systemOverride: String?) async throws -> String
        if let inferenceCoordinator {
            generate = { message, turnHistory, image, preview, systemOverride in
                // Identical arguments by construction: `MLXPromptAdapter.decompose` is the exact
                // inverse of the `compose` here (pinned by round-trip tests), so what reaches
                // `LocalLLMService.generate` through the seam is byte-for-byte what the direct
                // call would have passed. The stream's concatenation is the authoritative text.
                let request = LocalGenerationRequest(
                    messages: MLXPromptAdapter.compose(systemPrompt: systemOverride ?? prompt,
                                                       history: turnHistory,
                                                       userMessage: message),
                    images: image.map { [LocalImageInput(data: $0)] } ?? [],
                    maxOutputTokens: maxOutputTokens,
                    previewSink: preview)
                let stream = try await inferenceCoordinator.generate(request, expecting: selectedID)
                var assembled = ""
                for try await chunk in stream { assembled += chunk }
                return assembled
            }
        } else {
            generate = { message, turnHistory, image, preview, systemOverride in
                try await localService.generate(userMessage: message,
                                                systemPrompt: systemOverride ?? prompt,
                                                history: turnHistory,
                                                imageData: image,
                                                onToken: preview)
            }
        }

        // Preview containment (Plan FC P1). The live bubble used to receive every chunk verbatim,
        // partial `<tool_c…` markup included — the detokenizer splits tags across chunks, so even a
        // per-chunk regex could not have helped. The filter holds back only what is genuinely
        // ambiguous (a few characters that could still become a tag, or a line-initial `{` that
        // could be a bare call object) and releases ordinary prose as it arrives.
        let previewFilter = LocalProtocolStreamFilter()
        let containedPreview: ((String) -> Void)? = onToken.map { sink in
            { chunk in
                let visible = previewFilter.ingest(chunk)
                if !visible.isEmpty { sink(visible) }
            }
        }

        // Generate the response, streaming the contained preview to the UI as it is produced.
        var response: String
        do {
            // The image rides only the FIRST generation of the turn — tool-result follow-up
            // regenerations below re-answer over text, which is correct and far cheaper.
            do {
                response = try await generate(text, history, imageData, containedPreview, nil)
            } catch LocalInferenceError.visionNotAvailable {
                // The seam refuses an image to a model that loaded text-only; the direct path
                // refuses it inside `generate`. Same outcome, and deliberately the same words —
                // answering blind about a photo the model never saw is the failure both nets
                // exist to prevent.
                PrivacyLog.localModel(.imageRefused, model: PrivacyToken(selectedID.rawValue))
                response = LocalLLMService.visionWeightsUnavailableMessage
            }
            if let onToken {
                // Release whatever the filter was still holding and that never became protocol,
                // so ordinary text is not left out of the preview at end of stream.
                let tail = previewFilter.flush()
                if !tail.isEmpty { onToken(tail) }
            }
        } catch is CancellationError {
            // BK P4: a barge-in cancels the local generation. Propagate CancellationError UNWRAPPED
            // so ConversationTurnRunner maps it to onCancelled (partial reply not spoken) instead
            // of onError. Wrapping it in LLMError here would speak the generic error line.
            throw CancellationError()
        } catch let error as LocalLLMError {
            // Propagate .backgrounded unwrapped so callers (e.g. AgentScheduler) can
            // tell "can't run on-device in background" apart from a real failure and
            // defer rather than consuming the scheduled run.
            PrivacyLog.localModel(.generationFailed, error: SafeErrorSummary(error))
            throw error
        } catch {
            PrivacyLog.localModel(.generationFailed, error: SafeErrorSummary(error))
            throw LLMError.invalidResponse("Local model error: \(error.localizedDescription)")
        }

        // One classification for the whole completion: a usable call, broken protocol, or prose —
        // and, either way, the text that is safe to speak and store.
        var classification = LocalOutputPolicy.classify(response)

        // Announce-without-action (live-traced failure): the model says "I'm looking that
        // up" without emitting the tool_call markup, and the single-shot path would accept
        // the announcement as the answer. One corrective re-generation demanding the call
        // (or a direct answer) — bounded, never loops.
        //
        // Gated on `.prose`: an output that already contains protocol did not stall, it failed, and
        // the containment below is the right answer for it. (That gate is also what the old
        // `!lowered.contains("<tool_call>")` check inside `announcesToolIntent` amounted to.)
        if classification.kind == .prose, includeTools, nativeToolRouter != nil,
           Self.announcesToolIntent(classification.text) || Self.asksUserForLocation(classification.text) {
            PrivacyLog.localModel(.stalled)
            let correction = Self.asksUserForLocation(classification.text)
                ? "The user's location is already available to you — never ask for it. Call the where_am_i or get_weather tool now via <tool_call> in the exact format, then answer."
                : "You said you would look that up, but you did not call a tool. Either output the <tool_call> now in the exact format, or answer directly. Never say you will check — act."
            var correctiveHistory = history
            correctiveHistory.append((role: "assistant", content: classification.text))
            correctiveHistory.append((role: "user", content: correction))
            do {
                let second = try await generate(correction, correctiveHistory, nil, nil, nil)
                response = second
                classification = LocalOutputPolicy.classify(second)
            } catch is CancellationError {
                // BK P4: a barge-in during the correction cancels the turn. The old `try?` here
                // swallowed cancellation along with everything else.
                throw CancellationError()
            } catch {
                // A correction that could not run leaves the original answer standing, exactly as
                // the `try?` did — but the failure is now recorded rather than invisible.
                PrivacyLog.localModel(.generationFailed, detail: PrivacyToken("correction"),
                                      error: SafeErrorSummary(error))
            }
        }

        if let invocation = classification.invocation,
           let router = nativeToolRouter {
            let toolName = invocation.name
            let toolArgs = invocation.arguments

            // Execute the tool
            PrivacyLog.localModel(.toolCall, tool: PrivacyToken(toolName))
            // Plan KL P1/P2: counted and entered in the turn's ledger like every other model call.
            toolCallsDispatched += 1
            let ledgerID = ledgerDispatched(toolName, args: toolArgs)
            toolCallStatus = .executing(toolName)
            // Plan CU P1: the on-device path is deliberately not on `runToolLoop` (see the comment
            // above `sendLocal`), so its single tool round trip needs its own bracket. The
            // generation passes either side of it report themselves through `addGeneration`.
            let toolStartedAt = Date()
            let (outcome, completion) = await ActionCompletionReport.collect {
                await router.executeRoot(name: toolName, args: toolArgs)
            }
            TurnRecorder.addToolTime(since: toolStartedAt)
            toolCallStatus = .idle
            turnToolLedger.finished(ledgerID, outcome: outcome, completion: completion)

            // An unresolved outcome is not an error, and must not be handed to the model prefixed
            // as one — its own copy already says what is and isn't known.
            let resultText: String
            switch outcome {
            case .completed(let text): resultText = text
            case .outcomeUnknown(_, let message): resultText = message
            case .rejected(let reason), .failedBeforeExecution(let reason):
                resultText = "Error: \(reason)"
            }

            // The text the model produced alongside the call, already free of protocol.
            let textBefore = classification.text

            // Try to re-generate with tool result for a natural response
            var updatedHistory = history
            updatedHistory.append((role: "assistant", content: textBefore.isEmpty ? "Let me check that for you." : textBefore))
            updatedHistory.append((role: "user", content: "Tool '\(toolName)' returned: \(resultText). Please respond naturally to the user based on this result."))

            let finalResponse: String
            do {
                finalResponse = try await generate("Respond to the user based on the tool result above.",
                                                   updatedHistory, nil, nil, nil)
            } catch is CancellationError {
                throw CancellationError()   // BK P4: a barge-in during the tool-result regen cancels too
            } catch {
                // If re-generation fails, just return the tool result directly
                finalResponse = textBefore.isEmpty ? resultText : "\(textBefore) \(resultText)"
            }

            // BK P3 + FC P1: an all-markup / empty final must not reach the speaker. A model that
            // answers a tool result with a *second* `<tool_call>` is the case this closes: that
            // call is never executed (one tool round trip per turn stands), its markup is never
            // spoken, and what is left — prose if the model wrote any, an honest miss if it did
            // not — is what the wearer hears.
            let finalClassification = LocalOutputPolicy.classify(finalResponse)
            if finalClassification.carriesProtocol {
                PrivacyLog.localModel(.malformedOutput,
                                      detail: PrivacyToken("toolResult-\(finalClassification.kind.rawValue)"))
            }
            let cleanFinal: String
            if !finalClassification.text.isEmpty {
                cleanFinal = finalClassification.text
            } else if finalClassification.carriesProtocol {
                // Protocol-only: there is no answer to speak, and the tool result itself is a
                // machine-shaped string that this regeneration exists to translate. Say so rather
                // than reading it out or going silent.
                cleanFinal = Self.localMissMessage
            } else {
                // Genuinely empty completion — unchanged BK P3 contract, an error rather than
                // dead air at the speaker.
                throw LLMError.invalidResponse("Local")
            }
            conversationHistory.append(["role": "assistant", "content": cleanFinal])
            trimHistory()
            return cleanFinal
        }

        // No usable call. Everything below works on the cleaned text — protocol fragments,
        // complete or not, are already gone.
        let cleanResponse = classification.text

        // Broken protocol (FC P1): an unterminated frame, an orphan close tag, unparseable JSON
        // inside the tags, or a bare call object with no tags at all. None of those is an action —
        // nothing is executed and nothing is repaired by guessing — and none of them may be spoken
        // or stored as the assistant's answer. Prose the model wrote alongside the broken frame
        // survives; when there is none (or when it is only a promise to act), the wearer gets one
        // honest line instead.
        if classification.carriesProtocol {
            PrivacyLog.localModel(.malformedOutput,
                                  detail: PrivacyToken(classification.kind.rawValue))
            if cleanResponse.isEmpty || Self.announcesToolIntent(cleanResponse) {
                conversationHistory.append(["role": "assistant", "content": Self.localMissMessage])
                trimHistory()
                return Self.localMissMessage
            }
        }

        // Uncertainty gate (Plan BI): the local path can't reach `web_search` through a tool
        // loop, so a hedged or freshness-sensitive answer gets one transparent web-grounded
        // re-ask. Off-flag or confident answers pass straight through.
        //
        // An intent announcement that survived the corrective regen ("I will now search for…")
        // is treated as uncertainty too: the promised search actually happens here. And a
        // promise must NEVER be the spoken answer — if the re-ask can't improve on it (search
        // failed, flag off), an honest failure line replaces it rather than dead air after
        // "I'll look that up".
        let announcedIntent = Self.announcesToolIntent(cleanResponse)
        // Personal-data questions must never reach the web, even via the announced-intent
        // branch — "let me check your reminders" + web search = "I don't have access to your
        // personal reminders", the exact reply the detector's guard exists to prevent.
        let isPersonalData = UncertaintyDetector.isPersonalDataQuestion(text.lowercased())
        var finalAnswer = cleanResponse
        if !MedicalLLMRoutingPolicy.isEnforced(
               hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly),
           Config.localWebSearchFallbackEnabled, !isPersonalData,
           announcedIntent || UncertaintyDetector.assess(question: text, answer: cleanResponse).shouldSearch {
            finalAnswer = await UncertaintyReask.answer(
                question: text,
                originalAnswer: cleanResponse,
                vaultOnly: VaultOnlyPolicy.jobIsSealed,
                history: history,
                search: { query in try await WebSearchTool().execute(args: ["query": query]) },
                rewriteQuery: { q in
                    // A follow-up leaning on the conversation ("the other semi final?") is a
                    // junk literal query — one tiny generation makes it self-contained.
                    try await generate(
                        "Conversation:\n\(UncertaintyReask.conversationBlock(history: history))\n\nRewrite this follow-up as ONE self-contained web search query. If it already stands alone, output it unchanged. Output only the query, nothing else: \(q)",
                        [], nil, nil,
                        "You rewrite follow-up questions into standalone web search queries. Output only the query.")
                },
                regenerate: { grounding in try await generate(grounding, history, nil, nil, nil) }
            )
            // The re-ask swallows every throw to fall back on the original answer, cancellation
            // included; a barge-in during it must still cancel the turn (BK P4).
            try Task.checkCancellation()
            // A re-ask answers through the same model, so it can emit protocol too. Its markup is
            // no more speakable here than anywhere else.
            let reasked = LocalOutputPolicy.classify(finalAnswer)
            if reasked.carriesProtocol {
                PrivacyLog.localModel(.malformedOutput, detail: PrivacyToken("reask-\(reasked.kind.rawValue)"))
                finalAnswer = reasked.text.isEmpty ? cleanResponse : reasked.text
            }
        }

        // The never-speak-a-promise net: if the answer still announces an action (re-ask failed
        // or the fallback flag is off), replace it with an honest miss.
        if announcedIntent && finalAnswer == cleanResponse {
            finalAnswer = Self.localMissMessage
        }

        // BK P3: reject an empty local completion (immediate EOS / all-markup) instead of
        // speaking silence — matches the Anthropic/Gemini empty-completion guards.
        let validated = try Self.cleanedNonEmptyLocalAnswer(finalAnswer)
        conversationHistory.append(["role": "assistant", "content": validated])
        trimHistory()
        return validated
    }

    /// The one honest-miss line the local path speaks when a turn produced no answer it may say —
    /// a promise it never kept, or output that was nothing but broken tool protocol. It claims
    /// nothing happened and invites a retry, which is the only truthful thing left to say.
    static let localMissMessage = "I couldn't get that information just now — please ask me again."

    // MARK: - Local Agent Model

    /// Send a message through the on-device agent model (Gemma 4 via MLX).
    /// Used for fast-tier queries when agentic mode is enabled.
    /// Builds its own lightweight prompt and routes through sendLocal().
    func sendViaLocalAgent(_ text: String, locationContext: String? = nil, memoryContext: String? = nil, weatherContext: String? = nil) async throws -> String {
        replyFollowUps = []   // Plan KP P2: on-device prompts don't ask for them
        replyWebSources = []
        replySearchSuggestions = nil
        // Plan LA: the on-device agent's turn is its own, so its calls are the only ones the turn's
        // ledger holds. A spill to the cloud below starts the ledger again, as every cascade does.
        turnToolLedger.reset()
        let agentModelId = Config.agentModelId
        let hasNativeTools = nativeToolRouter != nil
        let device = Self.deviceInUse()   // Plan FY F3: read once for whichever prompt is built

        // Medical Local LLM Only resolves the model first, so the agent path cannot escape it or
        // hand the replacement local model a prompt too large for it. A cloud agent never reaches
        // this function: it is an ordinary turn on that model (`ModelTurnRoute.cloudAgent`).
        if MedicalLLMRoutingPolicy.isEnforced(
            hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly) {
            let requested = Config.savedModels.first(where: { $0.id == agentModelId })
                ?? ModelConfig(id: "requested-local-agent", name: "On-Device Agent",
                               provider: LLMProvider.local.rawValue, apiKey: "",
                               model: agentModelId, baseURL: "")
            let localConfig = try medicalInferenceModel(requested: requested)
            let leanPrompt = localConfig.llmProvider == .appleOnDevice
                ? Self.appleOnDevicePrompt(locationContext: locationContext, memoryContext: memoryContext,
                                           weatherContext: weatherContext, device: device)
                : await Self.leanOnDevicePrompt(
                    locationContext: locationContext, memoryContext: memoryContext,
                    hasImage: false, turn: text, weatherContext: weatherContext, device: device)
            PrivacyLog.model(.agentSelected, model: PrivacyToken(localConfig.model),
                             detail: PrivacyToken("medicalLocalOnly"))
            switch localConfig.llmProvider {
            case .local:
                return try await sendLocal(text, systemPrompt: leanPrompt, config: localConfig,
                                           includeTools: hasNativeTools)
            case .appleOnDevice:
                return try await sendAppleOnDevice(text, systemPrompt: leanPrompt,
                                                   includeTools: hasNativeTools, carryHistory: true)
            default:
                // `medicalInferenceModel` cannot return a remote model while this policy is active.
                throw LLMError.invalidConfiguration(MedicalLLMRoutingPolicy.unavailableMessage)
            }
        }

        // On-device agent: build a LEAN prompt (shared with the active-model path) — omits the
        // ~100 native-tool descriptions (~8k tokens) that OOM-crash a 2B model on a phone.
        // `sendLocal` appends its own reduced ~12-tool block, so the model still has usable tools.
        guard let localService = localLLMService else {
            throw LLMError.missingAPIKey("Local LLM service not initialized")
        }
        let leanPrompt = await Self.leanOnDevicePrompt(
            locationContext: locationContext, memoryContext: memoryContext, hasImage: false, turn: text,
            weatherContext: weatherContext, device: device)
        if !localService.isModelLoaded || localService.loadedModelId != agentModelId {
            try await localService.loadModel(agentModelId)
        }
        let localConfig = ModelConfig(
            id: "local-agent",
            name: "Local Agent",
            provider: LLMProvider.local.rawValue,
            apiKey: "",
            model: agentModelId,
            baseURL: ""
        )
        PrivacyLog.model(.agentSelected, model: PrivacyToken(agentModelId),
                         detail: PrivacyToken("local"))
        return try await sendLocal(text, systemPrompt: leanPrompt, config: localConfig, includeTools: hasNativeTools)
    }

    // MARK: - Helpers

    /// Trim history only when token budget is exceeded — no fixed turn limit.
    /// Preserves recent context and any messages containing memory commands or important decisions.
    private func trimHistory() {
        compressContextWindowIfNeeded()
    }

    /// History for one request.
    ///
    /// Small context rewrites aggressively — tool messages dropped, text clipped — because the
    /// point is to fit inside a few thousand tokens. Groq keeps the plain tail it has always used:
    /// `compactHistory` would also strip the tool exchange, and with tools *enabled* that changes
    /// an existing user's tool loop, which is not what a vision-image setting should do.
    ///
    /// The copy is in `provider`'s own shape: messages another provider wrote earlier in the
    /// conversation — a ChatGPT turn's `role: "tool"` result reaching the Vision model's photo turn
    /// on Anthropic, a cascade hop, a change of model — are converted for this request
    /// (`CrossProviderHistory`). The stored history is left as it was written.
    private func requestHistory(for provider: LLMProvider, smallContext: Bool) -> [[String: Any]] {
        let copy = budgetedRequestHistory(for: provider, smallContext: smallContext)
        guard let shape = CrossProviderHistory.shape(for: provider) else { return copy }
        let normalised = CrossProviderHistory.normalised(copy, for: shape)
        if normalised.converted > 0 {
            PrivacyLog.model(.historyConverted, provider: PrivacyToken(provider.rawValue),
                             count: normalised.converted, total: copy.count,
                             detail: PrivacyToken(shape.rawValue))
        }
        return normalised.history
    }

    private func budgetedRequestHistory(for provider: LLMProvider, smallContext: Bool) -> [[String: Any]] {
        lastRequestOmittedMessages = 0
        pendingTimeline = nil
        pendingTimelineSkip = .routeCarriesNoBlock
        // Plan KK P3: small context and Groq carry no timeline block (the cut they make is what the
        // block would undo), so they take no reading either: the pass would spend the wearer's
        // tokens on notes this route never shows.
        if smallContext {
            return Self.compactHistory(conversationHistory, keepLast: Self.smallContextHistoryTurns)
        }
        // Plan KL P1: a request fitted to the per-minute allowance on its shortest rung carries
        // the last two exchanges before this turn, and this turn whole.
        if PerMinuteFitScope.shortened {
            return PerMinuteFit.shortHistory(conversationHistory, turnStart: turnHistoryStart)
        }
        // Groq's free tier has tight TPM limits — trim history aggressively.
        if provider == .groq {
            return Array(conversationHistory.suffix(6))
        }
        // FM's ChatGPT budget and the on-device paths are unchanged (they never reach here with
        // this history, but the guard keeps the rule local).
        guard provider != .chatgpt, provider != .local, provider != .appleOnDevice else {
            noteTimelineReading(kept: conversationHistory)
            return conversationHistory
        }
        // Plan KK P3: the timeline's room comes off the history allowance first, so a request with
        // the block costs no more than one without it. What is reserved is the whole candidate
        // block; what is shown is decided by what this copy actually left out.
        let (thread, skip) = timelineThread(for: provider)
        pendingTimelineSkip = skip
        let floorIndex = jobHistoryFloor.floor(historyCount: conversationHistory.count)
        let reserve = thread.map { thread in
            TimelineRequestBlock.reserve(thread, floor: timelineFloor(in: thread.messages), timeZone: .current)
        } ?? 0
        // Plan GB P5: a budgeted request copy — this job's messages only, older exchanges dropped
        // to the allowance, the current turn protected — and images only where the model has not
        // yet answered from them (a photo is not resent on every tool round-trip).
        let allowance = Config.apiHistoryTokenBudget
        let budget = TimelineRequestBlock.historyAllowance(allowance, reserve: reserve)
        let selection = APIHistoryBudget.select(
            history: conversationHistory,
            protectedStart: min(turnHistoryStart, max(0, conversationHistory.count - 1)),
            floor: floorIndex,
            allowance: budget.history)
        lastRequestOmittedMessages = selection.omittedMessages
        let reading = noteTimelineReading(kept: selection.history, omitted: selection.omittedMessages)
        if let thread {
            pendingTimeline = TimelineRequestBlock.Request(thread: thread, reading: reading,
                                                           omittedMessages: selection.omittedMessages,
                                                           tokenCap: budget.blockCap)
        }
        if selection.omittedMessages > 0 {
            PrivacyLog.model(.contextBudget, provider: PrivacyToken(provider.rawValue),
                             count: selection.omittedMessages, total: allowance,
                             tokens: selection.estimatedTokens, detail: PrivacyToken("apiHistory"))
        }
        return HistoryHygiene.imagesOnlyAfterLastAssistant(selection.history)
    }

    /// The volatile tail for a request, with the budget's omission note when older messages were
    /// left out, and the conversation timeline (Plan KK P3) where coverage says it belongs: in
    /// place of the note when it covers everything that left, after it (and the note saying so)
    /// when it does not. `volatileTail` nil (a single-string provider) puts both at the prompt's
    /// end. `recallOffered`: this request declares `brain` and the model may call it.
    private func requestSystemParts(stable systemPrompt: String, volatileTail: String?,
                                    recallOffered: Bool) -> (stable: String, volatile: String?) {
        let omitted = lastRequestOmittedMessages
        let decision: TimelineRequestBlock.Decision
        if let pendingTimeline {
            decision = TimelineRequestBlock.decide(pendingTimeline, recallOffered: recallOffered,
                                                   timeZone: .current)
        } else {
            let routeSkip = pendingTimelineSkip == .routeCarriesNoBlock
            decision = .skipped(routeSkip || omitted > 0 ? (pendingTimelineSkip ?? .noThread) : .nothingOmitted)
        }
        recordTimeline(decision, omitted: omitted)
        let note = TimelineRequestBlock.workingContext(decision: decision) { partial in
            APIHistoryBudget.omissionNote(omitted, recallOffered: recallOffered, partialNotes: partial)
        }
        if let volatileTail {
            return (systemPrompt, [volatileTail, note.map { "\n\n" + $0 }].compactMap { $0 }.joined())
        }
        return (note.map { systemPrompt + "\n\n" + $0 } ?? systemPrompt, nil)
    }

    /// How many recent messages a small-context request carries.
    static let smallContextHistoryTurns = 4

    /// Reply ceiling for a turn with tools attached: a spoken answer or a tool call, not an
    /// essay. `AnthropicModelContract.outputCap` raises it for a model that thinks by default,
    /// whose thinking is drawn from the same allowance (Plan IE P3).
    static let toolTurnMaxTokens = 1_024

    /// Reply ceiling for a small-context *vision* turn. The lean prompt asks for one or two
    /// spoken sentences, and this is the hard stop that keeps a chatty model from spending the
    /// budget the setting exists to save. Text-only turns keep `Config.maxTokens`: without an
    /// image there is no image-token pressure, and truncating prose mid-sentence is worse than a
    /// slightly larger reply.
    static let smallContextVisionMaxTokens = 320

    static func compactHistory(_ history: [[String: Any]], keepLast: Int) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in history {
            let role = msg["role"] as? String ?? "user"
            if role == "tool" || role == "function" { continue }
            if Self.historyMessageHasImage(msg) {
                out.append(msg)
                continue
            }
            guard let text = Self.plainText(from: msg), !text.isEmpty else { continue }
            let clipped = text.count > 600 ? String(text.prefix(600)) + "…" : text
            let outRole = (role == "model") ? "assistant" : role
            out.append(["role": outRole, "content": clipped])
        }
        return Array(out.suffix(keepLast))
    }

    private static func historyMessageHasImage(_ message: [String: Any]) -> Bool {
        let blocks = (message["content"] as? [[String: Any]]) ?? (message["parts"] as? [[String: Any]]) ?? []
        return blocks.contains { block in
            if let type = block["type"] as? String, type == "image" || type == "image_url" { return true }
            return block["inlineData"] != nil
        }
    }

    private static func plainText(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        let blocks = (message["content"] as? [[String: Any]]) ?? (message["parts"] as? [[String: Any]]) ?? []
        let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Test seams

    /// Drive one on-device turn directly (Plan FC P1's containment harness).
    ///
    /// `sendLocal` is private because nothing in the app may bypass `sendMessage`'s routing to
    /// reach it; the containment regressions, though, have to exercise the real turn — parsing,
    /// tool dispatch, both regenerations, history insertion — rather than a helper in isolation.
    /// This wrapper is that entry point and has no production caller.
    func sendLocalForTesting(_ text: String,
                             systemPrompt: String = "You are a test.",
                             config: ModelConfig,
                             includeTools: Bool = true,
                             imageData: Data? = nil,
                             onToken: ((String) -> Void)? = nil) async throws -> String {
        try await sendLocal(text, systemPrompt: systemPrompt, config: config,
                            includeTools: includeTools, imageData: imageData, onToken: onToken)
    }

    /// Plan GC's fake-transport tests drive the real OpenAI-compatible turn — route selection, the
    /// Responses path, the fallback, history — through this wrapper, for the same reason as
    /// `sendLocalForTesting`: nothing in the app may bypass `sendMessage` to reach it. No
    /// production caller.
    func sendOpenAICompatibleForTesting(_ text: String, systemPrompt: String = "You are a test.",
                                        volatileTail: String? = nil, config: ModelConfig,
                                        includeTools: Bool = true, imageData: Data? = nil,
                                        onToken: ((String) -> Void)? = nil,
                                        onStreamReset: (() -> Void)? = nil) async throws -> String {
        try await sendOpenAICompatible(text, systemPrompt: systemPrompt, volatileTail: volatileTail,
                                       config: config, includeTools: includeTools, imageData: imageData,
                                       onToken: onToken, onStreamReset: onStreamReset)
    }

    /// The raw history dictionaries, for asserting on keys a (role, text) view cannot show — the
    /// Responses raw-items key in particular. Test-only.
    func rawConversationHistoryForTesting() -> [[String: Any]] {
        conversationHistory
    }

    /// Start a test from a history in any provider's wire shape — what an earlier turn on another
    /// provider left behind. Test-only.
    func seedRawConversationHistoryForTesting(_ history: [[String: Any]]) {
        conversationHistory = history
    }

    /// The durable turn history as plain (role, text) pairs — what a regression asserts was, and
    /// was not, persisted. Test-only; production reads `conversationHistory` directly.
    func conversationHistorySnapshotForTesting() -> [(role: String, content: String)] {
        conversationHistory.compactMap { turn -> (role: String, content: String)? in
            guard let role = turn["role"] as? String else { return nil }
            return (role: role, content: Self.plainText(from: turn) ?? "")
        }
    }

    /// The Direct-mode prompt layout for given per-turn inputs (Plan GB P5's prefix-stability
    /// regression). Test-only; production builds it inside `sendMessage`.
    static func promptLayoutForTesting(locationContext: String? = nil, memoryContext: String? = nil,
                                       hasImage: Bool = false, includeTools: Bool = true,
                                       nativeToolNames: [String] = ["get_weather", "web_search"],
                                       turn: String? = nil,
                                       offersFollowUps: Bool = true,
                                       device: AssistantIdentity.Device = .phone) async -> PromptLayout {
        await buildSystemPrompt(locationContext: locationContext, includeTools: includeTools,
                                includeOpenClaw: false, hasImage: hasImage,
                                nativeToolNames: nativeToolNames, memoryContext: memoryContext,
                                turn: turn, offersFollowUps: offersFollowUps, device: device)
    }

    /// Start a test from a known history. Test-only.
    func resetConversationHistoryForTesting(_ turns: [(role: String, content: String)] = []) {
        conversationHistory = turns.map { ["role": $0.role, "content": $0.content] }
    }

    /// The history's plain-text messages, as (role, content). Test-only.
    func conversationHistoryForTesting() -> [(role: String, content: String)] {
        conversationHistory.compactMap { message in
            guard let role = message["role"] as? String, let content = message["content"] as? String else { return nil }
            return (role, content)
        }
    }

    /// The (role, content) view the local path feeds back to the model, after FC P1's bounded
    /// sanitation. Test-only.
    func localHistoryViewForTesting(_ count: Int = 6) -> [(role: String, content: String)] {
        recentTupleHistory(count, stripToolMarkup: true)
    }

    /// Inject a hidden system message into conversation history.
    /// Used by the memory nudge to prompt periodic review without the user seeing it.
    func injectSystemMessage(_ message: String) {
        cancelOffConversationRun()
        conversationHistory.append(["role": "user", "content": message])
    }
}

// MARK: - ToolResult Helper

extension ToolResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Think Tag Stripping

extension LLMService {
    /// Strip `<think>...</think>` blocks from LLM output.
    /// Returns the spoken text (without think tags) and the extracted reasoning (if any).
    /// Strip `<tool_call>` markup + trim, then require a non-empty result (BK P3). A sub-1B local
    /// model can emit only `<tool_call>` markup (stripped to nothing) or an immediate EOS —
    /// `TextToSpeechService.speak` drops an empty string silently, so the turn is total dead air:
    /// no TTS, no tone, no HUD, no error. Anthropic and Gemini already reject an empty completion;
    /// the local path must too. Throws `invalidResponse("Local")` on empty so the turn surfaces as
    /// an error (which the P2b cascade can later act on) instead of silence. Pure + headless.
    ///
    /// FC P1: the cleanup itself now lives in `LocalOutputPolicy`, so this validator and the turn
    /// path cannot disagree about what counts as protocol — the regex here only ever removed a
    /// *complete* frame, which let an unterminated one through to the speaker.
    nonisolated static func cleanedNonEmptyLocalAnswer(_ raw: String) throws -> String {
        let cleaned = LocalOutputPolicy.speakableText(raw)
        guard !cleaned.isEmpty else { throw LLMError.invalidResponse("Local") }
        return cleaned
    }

    static func stripThinkTags(_ text: String) -> (spoken: String, reasoning: String?) {
        let hasOpen = text.contains("<think>")
        let hasClose = text.contains("</think>")
        guard hasOpen || hasClose else { return (text, nil) }
        return ThinkStreamFilter.strip(text, startsInThink: hasClose && !hasOpen)
    }

    static func applyQwenReasoning(to body: inout [String: Any], provider: LLMProvider, model: String, disableThinking: Bool) {
        guard provider == .groq || provider == .qwen, model.lowercased().contains("qwen") else { return }
        body["reasoning_format"] = "hidden"
        if disableThinking {
            body["reasoning_effort"] = "none"
        }
    }

    /// Groq's `gpt-oss` models return their reasoning in `message.reasoning` unless asked not to
    /// (reasoning guide, 2026-10-10; `reasoning_format` is not supported on them, and the two
    /// parameters cannot be combined). Nothing reads that text: it would only be carried in the
    /// tool-call message that goes back into a history Groq's limits already keep short. The model
    /// still reasons, and the reasoning still counts as output.
    nonisolated static func applyGroqReasoningVisibility(to body: inout [String: Any], provider: LLMProvider, model: String) {
        guard provider == .groq, ReasoningPolicy.groqFamily(model: model) != nil else { return }
        body["include_reasoning"] = false
    }

    /// The one-shot Chat Completions requests (summaries, frame analysis, structured output, the
    /// intent classifier) set their own small `max_tokens` and never passed through
    /// `ReasoningPolicy`. On a Groq `gpt-oss` model the reasoning that precedes every answer is
    /// drawn from that same cap, so a cap sized for the answer alone comes back with no content.
    /// This gives them what an Automatic conversation turn gets: the lowest effort, the raised cap
    /// and no reasoning text. Other providers are left exactly as they were. Call it before
    /// `applyOpenAITokenLimitShape`, which renames the key this raises.
    nonisolated static func applyGroqOneShotReasoning(to body: inout [String: Any], config: ModelConfig) {
        let provider = config.llmProvider
        guard provider == .groq, ReasoningPolicy.groqFamily(model: config.model) != nil else { return }
        let reasoning = config.oneShotReasoningResolution()
        if let cap = body["max_tokens"] as? Int {
            body["max_tokens"] = reasoning.outputCap(base: cap)
        }
        reasoning.apply(to: &body)
        applyGroqReasoningVisibility(to: &body, provider: provider, model: config.model)
    }

    /// OpenAI's own endpoints reject `max_tokens` on current models (o-series, GPT-5 and later):
    /// "Unsupported parameter: 'max_tokens' ... Use 'max_completion_tokens' instead." Older OpenAI
    /// models accept `max_completion_tokens` too, so every request that reaches OpenAI (or Azure
    /// OpenAI through a custom base URL) is renamed. Other OpenAI-compatible providers keep
    /// `max_tokens`, which is the only spelling several of them accept.
    nonisolated static func applyOpenAITokenLimitShape(to body: inout [String: Any], provider: LLMProvider, baseURL: String) {
        guard usesMaxCompletionTokens(provider: provider, baseURL: baseURL),
              let limit = body.removeValue(forKey: "max_tokens") else { return }
        body["max_completion_tokens"] = limit
    }

    nonisolated static func usesMaxCompletionTokens(provider: LLMProvider, baseURL: String) -> Bool {
        if provider == .openai { return true }
        guard provider == .custom,
              let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return false }
        return host == "api.openai.com" || host.hasSuffix(".openai.azure.com")
    }

    /// Bend a shared OpenAI-compatible body to what Mistral accepts. Applied to the outgoing body
    /// only, never to `conversationHistory`, so another provider still sees the original history.
    ///
    /// - `stream_options` is dropped. Mistral's request schema is closed
    ///   (`additionalProperties: false`) and has no such field, so the OpenAI-style usage opt-in is
    ///   a validation error there rather than an ignored extra. Nothing is lost: Mistral's stream
    ///   chunks carry `usage` on their own, which `StreamingUsageAccumulator` already reads.
    /// - Tool-call ids are rewritten to Mistral's shape (`mistralNormalisedToolCallIDs`).
    nonisolated static func applyMistralRequestShape(to body: inout [String: Any], provider: LLMProvider) {
        guard provider == .mistral else { return }
        body.removeValue(forKey: "stream_options")
        if let messages = body["messages"] as? [[String: Any]] {
            body["messages"] = mistralNormalisedToolCallIDs(messages)
        }
    }

    /// Mistral's request validator requires tool-call ids of exactly nine ASCII letters or digits
    /// on tokenizer v11 and older (`mistral-small-2506`); v13 and later only need a non-empty id,
    /// which a nine-character one also is. Our history doesn't always hold that shape: the parser
    /// falls back to `call_<n>`, and the model cascade can carry OpenAI's `call_…` ids into a
    /// Mistral turn. Every other id is rewritten, and each assistant `tool_calls[].id` and the tool
    /// message answering it go through one mapping, so the pair still lines up.
    ///
    /// Derived, never random: an id already in the right shape is kept, and any other id maps to
    /// a base-62 digest of itself, so the same messages always produce the same body. Kept ids are
    /// reserved first; a derived id that would clash with one already in the request is
    /// re-derived with a salt.
    nonisolated static func mistralNormalisedToolCallIDs(_ messages: [[String: Any]]) -> [[String: Any]] {
        // Every id in the request, in first-appearance order.
        var ids: [String] = []
        var seen = Set<String>()
        for message in messages {
            var found: [String] = []
            if let calls = message["tool_calls"] as? [[String: Any]] {
                found += calls.compactMap { $0["id"] as? String }
            }
            if message["role"] as? String == "tool", let id = message["tool_call_id"] as? String {
                found.append(id)
            }
            for id in found where seen.insert(id).inserted { ids.append(id) }
        }

        var used = Set(ids.filter(isMistralToolCallID))
        var mapping: [String: String] = [:]
        for id in ids where !isMistralToolCallID(id) {
            var salt = 0
            var candidate = mistralToolCallID(deriving: id, salt: salt)
            while used.contains(candidate) {
                salt += 1
                candidate = mistralToolCallID(deriving: id, salt: salt)
            }
            used.insert(candidate)
            mapping[id] = candidate
        }
        guard !mapping.isEmpty else { return messages }

        return messages.map { message in
            var message = message
            if let calls = message["tool_calls"] as? [[String: Any]] {
                message["tool_calls"] = calls.map { call in
                    guard let id = call["id"] as? String, let mapped = mapping[id] else { return call }
                    var call = call
                    call["id"] = mapped
                    return call
                }
            }
            if message["role"] as? String == "tool",
               let id = message["tool_call_id"] as? String, let mapped = mapping[id] {
                message["tool_call_id"] = mapped
            }
            return message
        }
    }

    nonisolated static func isMistralToolCallID(_ id: String) -> Bool {
        id.utf8.count == 9 && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    /// Nine base-62 characters from a 64-bit FNV-1a digest of the id (plus the salt, when one is
    /// needed). FNV rather than `Hasher`, whose seed changes every launch.
    nonisolated static func mistralToolCallID(deriving id: String, salt: Int) -> String {
        let source = salt == 0 ? id : "\(id)#\(salt)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var out = ""
        for _ in 0..<9 {
            out.append(alphabet[Int(hash % 62)])
            hash /= 62
        }
        return out
    }
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse(String)
    case invalidConfiguration(String)
    /// `rejection` is what the provider's answer classified as (Plan IE P0): its error type, its
    /// request id and a reason from a closed vocabulary. The `message` beside it is the provider's
    /// own sentence, shown to the person and never logged.
    case apiError(provider: String, statusCode: Int, message: String?, rejection: ProviderRejection? = nil)
    /// A streaming response died mid-flight — a mid-stream `error` event or a connection that
    /// ended before the terminator (`[DONE]` / `message_stop`). Partial content must never be
    /// returned as a successful turn (BM P9).
    case streamInterrupted(provider: String, reason: String)
    /// The model answered that it will not answer (`stop_reason: refusal`, Plan IE P3). The reply
    /// was reached and read; there is nothing in it to speak. Another model may answer.
    case modelDeclined(provider: String)
    /// The reply stopped at its output ceiling before any text or tool call (Plan IE P3): the
    /// allowance went on thinking. Nothing was said, so this is not a short answer.
    case outputTruncated(provider: String)
    /// The model's own context window filled while it worked on the turn — instructions, tool
    /// definitions and the tools' results together — and nothing was left to drop. Not a
    /// max-tokens stop: the answer never had room to start. `toolsRan` says whether a tool had
    /// already run, which decides whether another model may take the turn from the start.
    case contextOverflow(provider: String, toolsRan: Bool)
    /// Nothing came back within `FirstReplyPolicy`'s limit. Not a network failure: the offline
    /// handoff must not count it (`isSlowResponse`).
    case slowResponse(provider: String)

    static func isSlowResponse(_ error: Error) -> Bool {
        if case LLMError.slowResponse = error { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        case .invalidResponse(let provider): return "Invalid response from \(provider)"
        case .invalidConfiguration(let msg): return msg
        case .apiError(let provider, let code, let msg, _):
            if let msg { return "\(provider) error \(code): \(msg)" }
            return "\(provider) error: \(code)"
        case .streamInterrupted(let provider, let reason):
            return "\(provider) stream interrupted: \(reason)"
        case .modelDeclined(let provider):
            return "\(provider) declined to answer"
        case .outputTruncated(let provider):
            return "\(provider) ran out of room before it answered"
        case .slowResponse(let provider):
            return "\(provider) took too long to answer"
        case .contextOverflow(let provider, _):
            return "\(provider) couldn't fit this request in its window — choose a cloud model in Settings → Assistant → AI Models for requests like this"
        }
    }
}

/// One turn's provider-search state, shared by the rounds of its tool loop (Plan KZ).
final class ProviderSearchTurn {
    /// The credential the turn is sent with, for the refusal memory's fingerprint only.
    let credential: String
    var spec: ProviderSearchSpec?
    /// The turn has decided; an attached search stays attached.
    var settled = false
    /// Retried after a refusal, or dropped mid-turn by a boundary: our own tool for the rest of
    /// the turn.
    var forcedOurTool = false
    /// The search was dropped mid-turn and this turn's history rewritten without its blocks: a
    /// request copy taken before must be taken again. Read once.
    var historyChanged = false

    func takeHistoryChanged() -> Bool {
        defer { historyChanged = false }
        return historyChanged
    }

    init(credential: String) {
        self.credential = credential
    }
}

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
        case .minimax: return URL(string: "https://platform.minimaxi.com")
        case .xai: return URL(string: "https://console.x.ai")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .qwen: return URL(string: "https://dashscope.console.aliyun.com/apiKey")
        case .zai, .chatgpt, .custom, .local, .appleOnDevice: return nil
        }
    }

    /// Whether this provider uses the OpenAI-compatible API format
    var isOpenAICompatible: Bool {
        switch self {
        // .chatgpt speaks the Responses API, not chat completions — its own send path.
        case .anthropic, .gemini, .geminiVertex, .chatgpt, .local, .appleOnDevice: return false
        case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom: return true
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

    /// Default model for the provider
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openai: return "gpt-4o"
        case .chatgpt: return ChatGPTOAuth.defaultModel
        case .gemini: return "gemini-2.0-flash"
        case .geminiVertex: return "gemini-2.0-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .zai: return "glm-4.5"
        case .qwen: return "qwen3.5-plus"
        case .minimax: return "MiniMax-M2.7"
        case .xai: return "grok-4"
        case .openrouter: return "anthropic/claude-sonnet-4"
        case .custom: return "gpt-4o"
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

    /// Whether this provider supports listing models via API
    var supportsModelListing: Bool {
        switch self {
        case .local, .appleOnDevice, .geminiVertex: return false
        default: return true   // .chatgpt lists from its static codex catalog
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

    /// Optional conversation store — used to persist LLM-generated summaries
    /// when the context window is compressed.
    weak var conversationStore: ConversationStore?

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

    /// Session the SSE streaming helpers use. Injectable purely so tests can stub `URLProtocol`
    /// and exercise the stream parsing/error paths headlessly (BM P9); production uses `.shared`.
    var streamingSession: URLSession = .shared


    #if canImport(FoundationModels)
    private var _appleSession: Any?
    @available(iOS 26.0, *)
    private var appleSession: LanguageModelSession? {
        get { _appleSession as? LanguageModelSession }
        set { _appleSession = newValue }
    }
    #endif

    /// Conversation history for multi-turn context.
    /// No artificial turn limit — history persists for the full conversation session.
    /// Context window is managed by token-aware compaction, not a fixed turn count.
    private var conversationHistory: [[String: Any]] = []

    /// Maximum estimated tokens before compacting the context window.
    /// When exceeded, older messages are summarized and compressed rather than dropped blindly.
    private let maxEstimatedTokens = 80_000

    /// Maximum tool call iterations to prevent infinite loops
    private let maxToolCallIterations = 5

    /// Build the full system prompt, optionally including location, tools, memory, and vision context.
    /// When `promptSections` is provided (from the ConversationClassifier), irrelevant sections are
    /// stripped to reduce token count. When nil, all sections are included (backward compatible).
    /// The lean system prompt for an on-device model: persona/behavior + location + memory, but
    /// NOT the ~100 native-tool descriptions (~8k tokens) that OOM a 2B model on a phone, and none
    /// of the heavy optional contexts (playbook/shortcuts/OpenClaw). `sendLocal` appends its own
    /// reduced tool block, so the model still has usable tools. Used by every on-device path
    /// (active-model `sendMessage` and fast-tier `sendViaLocalAgent`) so they can't diverge.
    static func leanOnDevicePrompt(locationContext: String?, memoryContext: String?, hasImage: Bool, turn: String, weatherContext: String? = nil) async -> String {
        var prompt = await buildSystemPrompt(
            locationContext: locationContext, includeTools: false, includeOpenClaw: false,
            hasImage: hasImage, memoryContext: memoryContext, turn: turn)
        if let weatherContext {
            prompt += "\n\nCURRENT WEATHER (fetched just now — answer from this; do NOT call get_weather and do NOT say you will check): \(weatherContext)"
        }
        // Gemma-style templates have no separate system channel — this whole prompt is merged
        // into the model's first *user* turn, and a small model can flip roles and reply to
        // "OpenGlasses" instead of the wearer. Pin the speaker identity explicitly.
        return prompt + "\n\nThe person speaking to you is the user wearing the glasses. Address them directly as \"you\". Never address OpenGlasses — that is your own name."
    }

    private static func buildSystemPrompt(locationContext: String?, includeTools: Bool, includeOpenClaw: Bool, hasImage: Bool, nativeToolNames: [String] = [], nativeToolDescriptions: [(name: String, description: String)] = [], gatewayToolNames: [String] = [], memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, turn: String? = nil) async -> String {
        // Agent personality mode: soul.md + skills.md + memory.md replace the standard prompt
        var prompt: String
        if Config.agentModeEnabled, let agentContext, !agentContext.isEmpty {
            prompt = agentContext
        } else {
            prompt = Config.systemPrompt
        }

        // Helper: check if a section should be included. When promptSections is nil (no classifier), include everything.
        let shouldInclude: (ConversationClassifier.PromptSections) -> Bool = { section in
            guard let sections = promptSections else { return true }
            return sections.contains(section)
        }

        // Ensure vision awareness is always present, even if user has a custom system prompt
        if shouldInclude(.vision) && !prompt.lowercased().contains("vision") && !prompt.lowercased().contains("camera") {
            prompt += """

            VISION & CAMERA:
            - The glasses have a camera. When the user says "look at this", "what is this", "read this", "identify this", "take a photo", or similar, a photo will be captured and sent to you automatically.
            - You CAN see images — never say you lack camera or vision access.
            - For text/signs/menus in foreign languages: transcribe the original text, then translate it.
            - For objects, products, landmarks: identify and describe them.
            - After reading text from an image, offer to copy it to clipboard or translate it.
            """
        }

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
                // Plan BM P4: domains the model must route through a tool, never self-answer.
                let routingRules = SystemPromptBuilder.routingRules(toolNames: nativeToolNames)
                if !routingRules.isEmpty {
                    toolSection += "\n\nMANDATORY ROUTING:\n" + routingRules
                }

                // Inject user-defined custom tool descriptions
                let customTools = Config.customTools.filter { Config.isToolEnabled($0.name) }
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

            toolSection += """

            TOOL USAGE RULES:
            CRITICAL: NEVER tell the user a tool is "not configured" or "not set up" — ALWAYS call the tool and let it handle errors. The tools check configuration internally and return helpful messages. Your job is to call them, not to guess their state.
            1. ALWAYS speak a brief verbal acknowledgment BEFORE calling any tool. This prevents awkward \
            silence while the tool executes. Examples:
               - "Sure, let me check the weather." then call get_weather.
               - "Got it, searching for that now." then call web_search.
               - "One moment, looking that up." then call web_search.
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
        if hasImage {
            prompt += """


            VISION INPUT:
            This turn includes an image captured from the user's glasses camera. You can analyze that image for this response.
            Do not say you lack camera or image access when an image is attached. If the image is unclear, say what you can and cannot make out.

            IDENTIFY & OCR:
            When the user asks to "identify", "read", "OCR", or "what does this say", carefully read ALL text visible in the image.
            - For signs, menus, labels, documents: transcribe the text accurately.
            - For foreign language text (e.g. Japanese, Chinese, Korean, Arabic, etc.): first transcribe the original text, then provide a translation into the user's language (English by default). Format as: "[Original text] — [Translation]".
            - For objects, products, landmarks: describe what you see and identify it.
            - For barcodes/QR codes: note their presence even if you can't decode them.
            """
        }
        if let memory = memoryContext {
            prompt += "\n\n\(memory)"
            prompt += """


            MEMORY INSTRUCTIONS:
            You can remember facts about the user by including [REMEMBER: key = value] in your response.
            You can forget facts with [FORGET: key]. These tags will be stripped before speaking.
            Memories persist across all conversations — they are the bridge between sessions.

            What to remember: names, preferences, family members, routines, interests, important dates, relationships, stated goals.
            Only remember when the user explicitly shares personal info — don't infer or assume.

            Memory hygiene — keep memory accurate and compact:
            - Before adding a fact, check the existing memories listed above. If one already covers that key, update it rather than creating a duplicate.
            - Merge related facts when possible (e.g. "partner = Alex" plus "Alex's birthday is March 5" → update partner entry to include both).
            - For time-sensitive facts (e.g. "at the airport", "working on a presentation"), include a date or context so staleness can be evaluated later.
            - Use [FORGET: key] to remove facts the user corrects or that are clearly no longer true.
            - When the user says "forget X" or "that's wrong", always issue a [FORGET] command before storing the correction.
            """
        }
        if let playbook = playbookContext {
            prompt += "\n\n\(playbook)"
        }
        // Models have no clock — without this one ~15-token line they answer date/time
        // reasoning from their training cutoff, confidently wrong ("local LLM doesn't
        // know day or time"). Unconditional: cheap enough for every turn, both paths.
        prompt += "\n\nCURRENT DATE & TIME: \(Self.currentDateTimeLine())"

        if let location = locationContext {
            prompt += "\n\nUSER LOCATION: \(location)"
        }
        if let nowPlaying = nowPlayingContext {
            prompt += "\n\n\(nowPlaying)"
        }
        // Inject voice-taught skills
        if shouldInclude(.tools), let skills = VoiceSkillStore.shared.promptContext(for: turn) {
            prompt += "\n\n\(skills)"
        }
        // Inject Field Assist vault content when a session is active.
        // This grounds the LLM in domain knowledge (refrigeration, IT, health) with strict source attribution.
        if let vaultContext = FieldSessionService.shared.promptContext() {
            prompt += "\n\n\(vaultContext)"
        }
        // Inject the active project's knowledge-base grounding when it has documents (Plan AN).
        if let projectContext = ProjectContextService.shared.promptContext() {
            prompt += "\n\n\(projectContext)"
        }
        // Inject the pages read so far when a reading session is live (Plan BT). Ungated by the
        // classifier on purpose: mid-book questions ("who is she?") match no keyword list, so the
        // live session is the signal — same call the playbook context makes. Here rather than as a
        // threaded parameter because this function is on every path (the lean on-device prompt
        // included), so local, cloud and cloud-agent all get it from this one line. The turn lets
        // the P4 catch-up retrieval pick which confirmed-read earlier passages ride along.
        if let readingContext = ReadingCompanionService.shared.promptContext(turn: turn) {
            prompt += "\n\n\(readingContext)"
        }
        // Inject project-scoped notes for the active job (what the user is mid-way through).
        if Config.projectMemoryEnabled,
           let session = FieldSessionService.shared.activeSession, session.isActive {
            let eligible = ProjectMemoryScope.eligible(
                BrainStore.shared.projectMemories(for: session.id), activeProject: session.id)
            let block = ProjectMemoryFormatter.block(eligible)
            if !block.isEmpty { prompt += "\n\n\(block)" }
        }
        // Inject social context (people the user knows)
        if shouldInclude(.social), let social = SocialContextStore.shared.promptContext() {
            prompt += "\n\n\(social)"
        }
        // Inject installed ClawHub skills
        if shouldInclude(.openClaw), let skillContext = InstalledSkillStore.shared.promptContext(for: turn) {
            prompt += "\n\n\(skillContext)"
        }
        // Always append the prompt-injection / untrusted-content policy. This is a security
        // baseline — it is never stripped by the classifier and applies in every mode.
        prompt += PromptInjectionPolicy.systemPromptPolicy
        return prompt
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

    /// The shared tool-dispatch step used by every provider's tool loop (Plan BG P3): native tools
    /// via `NativeToolRouter`, else the OpenClaw bridge, else a failure. Status transitions flow to
    /// the published `toolCallStatus`. Yield detection and the parse-error path live in the
    /// `ToolDispatcher` value type so the whole step is unit-testable with a mock executor.
    private func makeToolDispatcher() -> ToolDispatcher {
        ToolDispatcher(
            execute: { [weak self] name, args, rawArgs in
                guard let self else { return .failure("Service unavailable") }
                if let router = self.nativeToolRouter {
                    return await router.handleToolCall(name: name, args: args)
                } else if let bridge = self.openClawBridge, Config.isOpenClawAgentActive {
                    let taskDesc = args["task"] as? String ?? (rawArgs ?? String(describing: args))
                    return await bridge.delegateTask(task: taskDesc, toolName: name)
                }
                return .failure("No tool handler available")
            },
            onStatus: { [weak self] status in self?.toolCallStatus = status }
        )
    }

    /// - Parameter onToken: optional per-token callback for streaming the assistant reply into the
    ///   UI as it's generated (honoured by the Anthropic, OpenAI-compatible, and local providers).
    /// - Parameter onStreamReset: invoked at the start of each streamed tool-loop iteration so the
    ///   caller can clear its accumulated bubble — intermediate tool-turn text must never
    ///   concatenate with the final reply (BM P9).
    func sendMessage(_ text: String, locationContext: String? = nil, imageData: Data? = nil, memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        isProcessing = true
        defer {
            isProcessing = false
            // A "new topic" requested DURING this turn (the model called the new_topic tool)
            // applies now that the turn is complete — clearing mid-loop would orphan the
            // pending tool_result and 400 the next request.
            if pendingHistoryClear {
                pendingHistoryClear = false
                clearHistory()
                NSLog("[LLMService] History cleared (deferred new-topic request)")
            }
        }

        // Compress context window if conversation history has grown too large
        // Use LLM summarization in agentic mode, heuristic fallback otherwise
        if Config.agentModeEnabled {
            await compressContextWindowWithLLM()
        } else {
            compressContextWindowIfNeeded()
        }

        guard let modelConfig = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured — add one in Settings")
        }

        let provider = modelConfig.llmProvider
        let isOnDevice = (provider == .local || provider == .appleOnDevice)
        let hasNativeTools = nativeToolRouter != nil
        let includeOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil
        let includeTools = hasNativeTools || includeOpenClaw
        let nativeToolNames = nativeToolRouter?.registry.toolNames ?? []   // used by the agent-plan block too

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

        let fullPrompt: String
        if isOnDevice {
            fullPrompt = await Self.leanOnDevicePrompt(
                locationContext: locationContext, memoryContext: memoryContext,
                hasImage: imageData != nil, turn: text)
        } else {
            let nativeToolDescriptions = nativeToolRouter?.registry.toolDescriptions(for: nativeToolNames) ?? []
            let gatewayToolNames = openClawBridge?.availableToolNames ?? []
            fullPrompt = await Self.buildSystemPrompt(locationContext: locationContext, includeTools: includeTools, includeOpenClaw: includeOpenClaw, hasImage: imageData != nil, nativeToolNames: nativeToolNames, nativeToolDescriptions: nativeToolDescriptions, gatewayToolNames: gatewayToolNames, memoryContext: memoryContext, agentContext: agentContext, playbookContext: playbookContext, nowPlayingContext: nowPlayingContext, shortcutsContext: shortcutsContext, promptSections: promptSections, turn: text)
        }

        var toolsLabel = ""
        if hasNativeTools { toolsLabel += " [NativeTools]" }
        if includeOpenClaw { toolsLabel += " [OpenClaw]" }
        print("🤖 Using model: \(modelConfig.name) (\(modelConfig.model) via \(provider.displayName))\(toolsLabel)")

        // Plan-then-execute (Plan S): for a multi-step request in agent mode, plan deliberately and
        // run each step through the supervisor-gated router, instead of the single-shot tool loop.
        // The planner sees the request alone (not chat history), and tool output never re-enters
        // planning — the structural prompt-injection defense. Falls back to single-shot when the
        // request can't be planned/validated (still safe; every call is supervised either way).
        if Config.agentModeEnabled, hasNativeTools, imageData == nil, await classifyMultiStep(text) {
            if let summary = await runAgentPlan(request: text, nativeToolNames: nativeToolNames) {
                conversationHistory.append(["role": "user", "content": text])
                conversationHistory.append(["role": "assistant", "content": summary])
                trimHistory()
                return summary
            }
            print("🧭 Agent plan loop yielded no plan — falling back to single-shot")
        }

        // Image hygiene for EVERY provider, not just Anthropic (where the request builder
        // already prunes): stale images re-upload with every turn, and on the Gemini /
        // OpenAI-compatible paths an unpruned photo history overflowed the context window
        // outright. Prune here so all providers start the turn with at most one prior image.
        conversationHistory = HistoryHygiene.pruneImages(conversationHistory, keepLast: 1)

        let rawResponse: String
        switch provider {
        case .anthropic:
            rawResponse = try await sendAnthropic(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData, onToken: onToken, onStreamReset: onStreamReset)
        case .chatgpt:
            rawResponse = try await sendChatGPT(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData, onToken: onToken, onStreamReset: onStreamReset)
        case .gemini, .geminiVertex:
            rawResponse = try await sendGemini(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .local:
            rawResponse = try await sendLocal(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData, onToken: onToken)
        case .appleOnDevice:
            rawResponse = try await sendAppleOnDevice(text, systemPrompt: fullPrompt)
        case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            rawResponse = try await sendOpenAICompatible(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData, onToken: onToken, onStreamReset: onStreamReset)
        }

        // Local reasoning models (LFM2.5) are stripped at the generate layer —
        // LocalLLMService owns the template-opened <think> handling and every local
        // consumer needs the clean answer, not just this path. Surface the suppressed
        // chain-of-thought for the prompt inspector and return the (already clean) text.
        if provider == .local, let localThink = localLLMService?.lastReasoning {
            lastReasoning = localThink
            return rawResponse
        }

        // Strip <think> tags: keep reasoning in history but don't speak it
        if Config.agentModeEnabled {
            let (spoken, reasoning) = Self.stripThinkTags(rawResponse)
            lastReasoning = reasoning
            if let reasoning {
                NSLog("[LLMService] Think: %@", String(reasoning.prefix(200)))
            }
            return spoken
        }

        lastReasoning = nil
        return rawResponse
    }

    // MARK: - Model Cascade (BK P2b)

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
    func sendMessageCascading(_ text: String, locationContext: String? = nil, imageData: Data? = nil, memoryContext: String? = nil, agentContext: String? = nil, playbookContext: String? = nil, nowPlayingContext: String? = nil, shortcutsContext: String? = nil, promptSections: ConversationClassifier.PromptSections? = nil, backgrounded: Bool = false, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil, onModelSwitch: ((_ from: ModelConfig?, _ to: ModelConfig?, _ failure: ModelFallbackChain.FailureClass) async -> Void)? = nil) async throws -> String {

        func send() async throws -> String {
            try await sendMessage(text, locationContext: locationContext, imageData: imageData, memoryContext: memoryContext, agentContext: agentContext, playbookContext: playbookContext, nowPlayingContext: nowPlayingContext, shortcutsContext: shortcutsContext, promptSections: promptSections, onToken: onToken, onStreamReset: onStreamReset)
        }

        let candidates = ModelFallbackChain.candidates(
            activeId: Config.activeModelId, saved: Config.savedModels,
            fallbackOrder: Config.modelFallbackOrder)
        guard Config.modelCascadeEnabled, candidates.count > 1 else {
            return try await send()
        }

        let startId = Config.activeModelId
        let historySnapshot = conversationHistory
        let savedById = Dictionary(Config.savedModels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        defer {
            Config.setActiveModelId(startId)
            refreshActiveModel()
        }

        return try await ModelCascade.run(
            candidates: candidates,
            needs: .init(requiresVision: imageData != nil, isBackgrounded: backgrounded),
            maxAttempts: min(candidates.count, 4),
            isCancelled: { Task.isCancelled },
            onSwitch: { from, to, failure in
                // Rewind the partial UI stream and log the hop; P2c narrates it out loud.
                onStreamReset?()
                print("🔀 Model cascade: \(from.id) → \(to.id) (\(failure))")
                await onModelSwitch?(savedById[from.id], savedById[to.id], failure)
            },
            attempt: { [weak self] candidate in
                guard let self else { throw LLMError.invalidConfiguration("LLM service released") }
                // Start each attempt from the clean pre-turn history so a failed hop doesn't leave a
                // dangling/duplicated turn, and point the active model at this candidate.
                self.conversationHistory = historySnapshot
                Config.setActiveModelId(candidate.id)
                self.refreshActiveModel()
                return try await send()
            }
        )
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
        NSLog("[LLMService] Agent plan ran %d/%d steps (aborted=%@)",
              result.completedSteps, result.totalSteps, result.aborted ? "yes" : "no")
        return result.summary
    }

    /// A stateless, tools-off completion for the planner: it sees only the system prompt + the
    /// request, never the live conversation history (planning must use trusted context only, and
    /// must not pollute the chat). History is snapshotted and restored even on error.
    /// Stateless, tool-free completion against the user's active provider (honors on-device
    /// models). Used by lightweight features like recall summarization.
    func completeStateless(_ text: String, system: String) async throws -> String {
        guard let config = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured")
        }
        let snapshot = conversationHistory
        conversationHistory = []
        defer { conversationHistory = snapshot }

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
            return try await sendAppleOnDevice(text, systemPrompt: system)
        case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return try await sendOpenAICompatible(text, systemPrompt: system, config: config, includeTools: false, imageData: nil)
        }
    }

    /// Clear conversation history (e.g. when starting fresh or switching providers)
    /// Set when a "new topic" arrives while a turn is in flight; applied in `sendMessage`'s defer.
    private var pendingHistoryClear = false

    /// Clear the conversation history — immediately when idle, or after the in-flight turn
    /// completes when the model itself requested it via the `new_topic` tool (a mid-loop wipe
    /// would orphan the pending tool_result).
    func requestHistoryClear() {
        if isProcessing {
            pendingHistoryClear = true
        } else {
            clearHistory()
        }
    }

    func clearHistory() {
        conversationHistory.removeAll()
    }

    /// Load a persisted conversation thread into the in-memory history.
    /// Called when the user resumes a past conversation from the history view.
    /// The full thread is loaded and then compacted if it exceeds the token budget,
    /// preserving key signals from earlier messages.
    func loadConversationHistory(_ messages: [(role: String, content: String)]) {
        conversationHistory.removeAll()
        for msg in messages {
            conversationHistory.append(["role": msg.role, "content": msg.content])
        }
        // Compact immediately if the restored history is too large for the context window
        compressContextWindowIfNeeded()
        NSLog("[LLM] Loaded %d messages from conversation history (%d after compaction)",
              messages.count, conversationHistory.count)
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

        let newTokens = conversationHistory.reduce(0) { total, msg in
            let content = msg["content"] as? String ?? ""
            return total + max(content.count / 4, 50)
        }

        NSLog("[LLM] Context compacted: %d → %d messages (~%d → ~%d tokens, %d signals preserved)",
              originalCount, conversationHistory.count, estimatedTokens, newTokens, signals.count)
    }

    // MARK: - LLM-Based Compression

    /// Compress the context window using an LLM to summarize old messages.
    /// Falls back to the heuristic compressor on failure.
    private func compressContextWindowWithLLM() async {
        let estimatedTokens = HistoryHygiene.estimatedTokens(conversationHistory)   // image-aware (Plan BF)

        guard estimatedTokens > maxEstimatedTokens, conversationHistory.count > 6 else { return }

        // Select messages to compress vs keep
        let keepCount = max(6, conversationHistory.count / 3)
        let messagesToCompress = Array(conversationHistory.prefix(conversationHistory.count - keepCount))
        let messagesToKeep = Array(conversationHistory.suffix(keepCount))

        // Try LLM summarization
        if let summary = await summarizeMessages(messagesToCompress) {
            let originalCount = conversationHistory.count
            let summaryMessage: [String: Any] = [
                "role": "user",
                "content": "[Conversation summary — \(messagesToCompress.count) earlier messages]\n\(summary)"
            ]
            conversationHistory = [summaryMessage] + messagesToKeep

            let newTokens = conversationHistory.reduce(0) { total, msg in
                let content = msg["content"] as? String ?? ""
                return total + max(content.count / 4, 50)
            }
            NSLog("[LLM] LLM-compressed: %d → %d messages (~%d → ~%d tokens)",
                  originalCount, conversationHistory.count, estimatedTokens, newTokens)

            // Persist the summary to the active conversation thread
            if let store = conversationStore, let threadId = store.activeThreadId {
                await MainActor.run { store.updateCompressedSummary(summary, for: threadId) }
            }
            return
        }

        // Fallback to heuristic compression
        NSLog("[LLM] LLM summarization failed, falling back to heuristic compression")
        compressContextWindowIfNeeded()
    }

    /// Make a standalone LLM call to summarize a set of messages.
    /// Uses no tools and a small max_tokens budget. Returns nil on failure.
    private func summarizeMessages(_ messages: [[String: Any]]) async -> String? {
        guard let modelConfig = Config.activeModel else { return nil }

        // Build a text representation of the messages
        var transcript = ""
        for msg in messages {
            let role = msg["role"] as? String ?? "unknown"
            let content: String
            if let text = msg["content"] as? String {
                content = text
            } else if let parts = msg["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            } else {
                continue
            }
            // Truncate very long messages to avoid blowing up the summarization call
            let truncated = content.count > 500 ? String(content.prefix(500)) + "…" : content
            transcript += "\(role): \(truncated)\n"
        }

        guard !transcript.isEmpty else { return nil }

        let summarizationPrompt = """
        Summarize the following conversation excerpt concisely. Preserve:
        - All user-stated facts, names, and preferences
        - Decisions made and commitments given
        - Tool calls and their key results
        - Memory commands ([REMEMBER], [FORGET])
        - Any unresolved questions or action items

        Keep it under 300 words. Use plain text, no formatting.

        CONVERSATION:
        \(transcript)
        """

        let provider = modelConfig.llmProvider

        do {
            // Use a lightweight request — no tools, short max_tokens
            switch provider {
            case .anthropic:
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                AnthropicAuth.apply(credential: await AnthropicAuth.resolveCredential(apiKey: modelConfig.apiKey), to: &request)
                request.timeoutInterval = 15
                let body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": 512,
                    "system": "You are a conversation summarizer. Be concise and factual.",
                    "messages": [["role": "user", "content": summarizationPrompt]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String else { return nil }
                return text

            case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 15
                let body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": 512,
                    "messages": [
                        ["role": "system", "content": "You are a conversation summarizer. Be concise and factual."],
                        ["role": "user", "content": summarizationPrompt]
                    ]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String else { return nil }
                return text

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 15) else { return nil }
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": "You are a conversation summarizer. Be concise and factual."]]],
                    "contents": [["role": "user", "parts": [["text": summarizationPrompt]]]],
                    "generationConfig": ["maxOutputTokens": 512]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let text = parts.first?["text"] as? String else { return nil }
                return text

            case .chatgpt:
                guard let json = await chatgptStatelessResponse(
                    model: modelConfig.model,
                    instructions: "You are a conversation summarizer. Be concise and factual.",
                    userContent: summarizationPrompt, timeout: 15) else { return nil }
                let text = ResponsesTranslator.parseOutput(json).text
                return text.isEmpty ? nil : text

            case .local, .appleOnDevice:
                // Not worth running summarization on local models — use heuristic
                return nil
            }
        } catch {
            NSLog("[LLM] Summarization request failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Stateless one-shot vision analysis: sends `systemPrompt` + `userText` + a JPEG frame to the
    /// active provider with no tools and a small token budget, and does NOT mutate conversation
    /// history. Used by the Assistive Modes (A3) ambient loop, which must not pollute the chat.
    /// Returns the raw model text, or nil on failure / unsupported provider (local, appleOnDevice).
    func analyzeFrame(systemPrompt: String, userText: String, imageData: Data, maxTokens: Int = 200) async -> String? {
        guard let modelConfig = Config.activeModel else { return nil }
        let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
        let provider = modelConfig.llmProvider

        do {
            switch provider {
            case .anthropic:
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                AnthropicAuth.apply(credential: await AnthropicAuth.resolveCredential(apiKey: modelConfig.apiKey), to: &request)
                request.timeoutInterval = 20
                let body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "system": systemPrompt,
                    "messages": [["role": "user", "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                        ["type": "text", "text": userText]
                    ]]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String else { return nil }
                return text

            case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 20
                let body: [String: Any] = [
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
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String else { return nil }
                return text

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 20) else { return nil }
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": [
                        ["text": userText],
                        ["inlineData": ["mimeType": "image/jpeg", "data": base64]]
                    ]]],
                    "generationConfig": ["maxOutputTokens": maxTokens]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
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
            NSLog("[LLM] analyzeFrame request failed: %@", error.localizedDescription)
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
        guard let modelConfig = Config.activeModel else { return nil }
        let base64 = LLMImagePreparer.prepared(imageData).base64EncodedString()
        let provider = modelConfig.llmProvider
        let toolDescription = "Return the structured assessment for the image."

        do {
            switch provider {
            case .anthropic:
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                AnthropicAuth.apply(credential: await AnthropicAuth.resolveCredential(apiKey: modelConfig.apiKey), to: &request)
                request.timeoutInterval = 30
                let body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "system": systemPrompt,
                    "tools": [["name": toolName, "description": toolDescription, "input_schema": jsonSchema]],
                    "tool_choice": ["type": "tool", "name": toolName],
                    "messages": [["role": "user", "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                        ["type": "text", "text": userText]
                    ]]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.anthropic(data, toolName: toolName)

            case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 30
                let body: [String: Any] = [
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
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
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
                    "generationConfig": [
                        "maxOutputTokens": maxTokens,
                        "responseMimeType": "application/json",
                        "responseSchema": GeminiSchemaTranslator.translate(jsonSchema)
                    ]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
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
            NSLog("[LLM] analyzeFrameStructured request failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Stateless TEXT → JSON structured completion (no image, no conversation history) — the text sibling
    /// of `analyzeFrameStructured`. Cloud providers use forced tool-use / JSON mode; the on-device
    /// providers (Apple Foundation Models / local MLX) are prompted for JSON and parsed tolerantly, so
    /// the offline path works. Returns the JSON object, or nil on failure. Used by Study Mode generation.
    func completeStructured(systemPrompt: String, userText: String, jsonSchema: [String: Any],
                            toolName: String = "result", maxTokens: Int = 2048) async -> [String: Any]? {
        guard let modelConfig = Config.activeModel else { return nil }
        let provider = modelConfig.llmProvider
        let toolDescription = "Return the structured result."

        do {
            switch provider {
            case .anthropic:
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                AnthropicAuth.apply(credential: await AnthropicAuth.resolveCredential(apiKey: modelConfig.apiKey), to: &request)
                request.timeoutInterval = 45
                let body: [String: Any] = [
                    "model": modelConfig.model,
                    "max_tokens": maxTokens,
                    "system": systemPrompt,
                    "tools": [["name": toolName, "description": toolDescription, "input_schema": jsonSchema]],
                    "tool_choice": ["type": "tool", "name": toolName],
                    "messages": [["role": "user", "content": userText]]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.anthropic(data, toolName: toolName)

            case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
                var baseURL = modelConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.hasSuffix("/chat/completions") {
                    baseURL += baseURL.hasSuffix("/") ? "chat/completions" : "/chat/completions"
                }
                guard let url = URL(string: baseURL) else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 45
                let body: [String: Any] = [
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
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.openAI(data)

            case .gemini, .geminiVertex:
                guard var request = try? await geminiRequest(for: modelConfig, timeout: 45) else { return nil }
                let body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": [["role": "user", "parts": [["text": userText]]]],
                    "generationConfig": [
                        "maxOutputTokens": maxTokens,
                        "responseMimeType": "application/json",
                        "responseSchema": GeminiSchemaTranslator.translate(jsonSchema)
                    ]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                return StructuredVisionParser.gemini(data)

            case .chatgpt:
                return await chatgptStatelessStructured(
                    model: modelConfig.model, instructions: systemPrompt, userContent: userText,
                    toolName: toolName, toolDescription: toolDescription, jsonSchema: jsonSchema)

            case .appleOnDevice:
                let prompt = systemPrompt + "\n\nReturn ONLY a single valid JSON object matching the requested shape — no prose, no code fences."
                let text = try await sendAppleOnDevice(userText, systemPrompt: prompt)
                return AssessmentJSON.object(fromText: text)

            case .local:
                let prompt = systemPrompt + "\n\nReturn ONLY a single valid JSON object — no prose, no code fences."
                let text = try await sendLocal(userText, systemPrompt: prompt, config: modelConfig, includeTools: false)
                return AssessmentJSON.object(fromText: text)
            }
        } catch {
            NSLog("[LLM] completeStructured request failed: %@", error.localizedDescription)
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
            appleSession = nil
        }
        #endif
    }

    // MARK: - Anthropic Claude

    /// Route a request to the appropriate cloud provider for a given config.
    /// Used when a cloud model is selected as the agentic fast-tier model.
    private func sendCloud(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool) async throws -> String {
        switch config.llmProvider {
        case .anthropic:
            return try await sendAnthropic(text, systemPrompt: systemPrompt, config: config, includeTools: includeTools, imageData: nil)
        case .chatgpt:
            return try await sendChatGPT(text, systemPrompt: systemPrompt, config: config, includeTools: includeTools, imageData: nil)
        case .gemini, .geminiVertex:
            return try await sendGemini(text, systemPrompt: systemPrompt, config: config, includeTools: includeTools, imageData: nil)
        case .local, .appleOnDevice:
            throw LLMError.missingAPIKey("Local providers cannot be used as cloud agent")
        case .openai, .groq, .zai, .qwen, .minimax, .xai, .openrouter, .custom:
            return try await sendOpenAICompatible(text, systemPrompt: systemPrompt, config: config, includeTools: includeTools, imageData: nil)
        }
    }

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
            Task { @MainActor in UsageTracker.shared.noteUntrackedTurn() }
            return
        }
        recordUsage(provider: provider, model: model, tokensIn: usage.tokensIn, tokensOut: usage.tokensOut,
                    cacheWriteTokens: usage.cacheWriteTokens, cacheReadTokens: usage.cacheReadTokens)
    }

    /// Record already-parsed token counts (the streaming paths accumulate their own).
    private func recordUsage(provider: LLMProvider, model: String, tokensIn: Int, tokensOut: Int,
                             cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0) {
        guard tokensIn + tokensOut + cacheWriteTokens + cacheReadTokens > 0 else { return }
        Task { @MainActor in
            UsageTracker.shared.record(provider: provider, model: model, tokensIn: tokensIn, tokensOut: tokensOut,
                                       cacheWriteTokens: cacheWriteTokens, cacheReadTokens: cacheReadTokens)
        }
    }

    // Internal (not private) so the BM P9 fixture tests can drive the full streamed tool loop
    // through a stubbed `streamingSession`.
    func sendAnthropic(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        // An explicit API key wins; otherwise fall back to a connected Claude account (OAuth).
        let apiKey = await AnthropicAuth.resolveCredential(apiKey: config.apiKey)
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("Anthropic API key not configured — add a key or sign in with Claude")
        }

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

        // A tool_use block with an id but missing name/input can't be dispatched, yet still needs a
        // tool_result or the next request 400s (Plan BF). Its id is carried per-turn and answered
        // with a synthetic error alongside the real results.
        final class TurnState { var malformedIds: [String] = [] }
        let state = TurnState()

        let adapter = ProviderLoopAdapter(
            label: "Anthropic",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("Anthropic") }
                state.malformedIds = []

                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                AnthropicAuth.apply(credential: apiKey, to: &request)  // already resolved above

                // Turn hygiene (Plan BF): drop stale images that would otherwise re-upload every turn,
                // and repair any dangling tool_use so a single interrupted tool call can't 400 the whole
                // conversation. Applied to the sent copy AND written back so the fixes persist.
                self.conversationHistory = HistoryHygiene.repairDanglingToolUse(
                    HistoryHygiene.pruneImages(self.conversationHistory, keepLast: 1))

                // Prompt caching (Plan BF): the system prompt + tool schemas are large and byte-stable
                // within a session, so mark them ephemeral-cacheable. Anthropic then reads them from
                // cache on every follow-up turn instead of re-billing full input tokens each time.
                var body: [String: Any] = [
                    "model": config.model,
                    "max_tokens": includeTools ? 1024 : Config.maxTokens,
                    "system": [[
                        "type": "text",
                        "text": systemPrompt,
                        "cache_control": ["type": "ephemeral"]
                    ]],
                    "messages": self.conversationHistory
                ]

                if includeTools {
                    let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                    let toolsData: Data = await MainActor.run {
                        let tools = ToolDeclarations.anthropicTools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: self.nativeToolRouter?.mcpClient)
                        return (try? JSONSerialization.data(withJSONObject: tools)) ?? Data()
                    }
                    var tools = (try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? []
                    // Cache-breakpoint on the final tool caches the whole tools array as one prefix.
                    if !tools.isEmpty {
                        tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
                    }
                    body["tools"] = tools
                }

                if onToken != nil { body["stream"] = true }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                // Final-reply turns stream into the Chat tab when a streaming caller passes `onToken`;
                // the reconstructed content blocks + stop reason feed the shared tool loop unchanged.
                let content: [[String: Any]]
                let stopReason: String?
                if let onToken {
                    // New tool-loop iteration: clear the caller's accumulated bubble first, so an
                    // intermediate tool turn's text never concatenates with the final reply (BM P9).
                    onStreamReset?()
                    let flag = TokenDeliveryFlag()
                    (content, stopReason) = try await self.withTransientSSERetries(tokenFlag: flag) {
                        try await self.streamAnthropicContent(request: request, model: config.model) { token in
                            flag.mark()
                            onToken(token)
                        }
                    }
                } else {
                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMsg = (errorJson["error"] as? [String: Any])?["message"] as? String {
                            print("❌ Anthropic API error \(statusCode): \(errorMsg)")
                            throw LLMError.apiError(provider: "Anthropic", statusCode: statusCode, message: errorMsg)
                        }
                        throw LLMError.apiError(provider: "Anthropic", statusCode: statusCode, message: nil)
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let parsed = json["content"] as? [[String: Any]] else {
                        throw LLMError.invalidResponse("Anthropic")
                    }
                    content = parsed
                    stopReason = json["stop_reason"] as? String
                    self.recordUsage(provider: .anthropic, model: config.model, json: json)
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
                let text = content.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }.joined(separator: "\n")
                return AssistantTurn(text: text, toolCalls: toolCalls, payload: content)
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
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(toolName: outcome.invocation.name, content: resultContent)
                    self.conversationHistory.append([
                        "role": "user",
                        "content": [["type": "tool_result", "tool_use_id": id, "content": framed]]
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

        return try await runToolLoop(maxIterations: maxToolCallIterations, adapter: adapter,
                                     setStatus: { [weak self] in self?.toolCallStatus = $0 })
    }

    // MARK: - OpenAI-compatible

    /// Authorization header value for an OpenAI-compatible request, or nil for a keyless
    /// `.custom` endpoint (self-hosted Ollama/LM Studio/bridge — the save/list paths already
    /// allow an empty key for `.custom`, so the send path must too).
    nonisolated static func openAICompatibleAuthorization(provider: LLMProvider, apiKey: String) throws -> String? {
        guard apiKey.isEmpty else { return "Bearer \(apiKey)" }
        guard provider == .custom else {
            throw LLMError.missingAPIKey("\(provider.displayName) API key not configured")
        }
        return nil
    }

    /// A `.custom` endpoint that 400'd on a `tools` payload (some Ollama/LM Studio builds).
    /// Remembered for the session so later turns skip tools instead of re-tripping the 400.
    /// `static nonisolated(unsafe)` because it's flipped inside the nonisolated per-turn
    /// closure; a bool flag with one realistic writer needs no stronger isolation.
    nonisolated(unsafe) private static var customEndpointRejectsTools = false

    private func sendOpenAICompatible(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        let provider = config.llmProvider
        let apiKey = config.apiKey
        let authorization = try Self.openAICompatibleAuthorization(provider: provider, apiKey: apiKey)

        var baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseURL.hasSuffix("/chat/completions") {
            if baseURL.hasSuffix("/") {
                baseURL += "chat/completions"
            } else {
                baseURL += "/chat/completions"
            }
        }
        
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
            print("🖼️ Skipping image for model \(config.model) — vision disabled for this model configuration")
            // Drop the image but keep the text, and inform the model
            conversationHistory.append(["role": "user", "content": text + "\n[System note: The user attempted to send an image, but the current model (\(config.model)) does not support image analysis.]"])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()

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
                    request.setValue("https://github.com/straff2002/OpenGlasses", forHTTPHeaderField: "HTTP-Referer")
                    request.setValue("OpenGlasses", forHTTPHeaderField: "X-Title")
                }

                // OpenAI format: system prompt is a message in the array.
                // Groq's free tier has tight TPM limits — trim history aggressively.
                let historySlice = provider == .groq ? Array(self.conversationHistory.suffix(6)) : self.conversationHistory
                var messages: [[String: Any]] = [
                    ["role": "system", "content": systemPrompt]
                ]
                messages.append(contentsOf: historySlice)

                var body: [String: Any] = [
                    "model": config.model,
                    "max_tokens": includeTools ? 1024 : Config.maxTokens,
                    "messages": messages
                ]

                // Only attach Tools if the provider reliably supports function calling.
                // Custom endpoints get tools too (Gemini/vLLM/newer Ollama all speak OpenAI
                // function calling); the ones that 400 on a `tools` payload are retried once
                // without tools below and remembered for the rest of the session.
                let providerSupportsTools = provider == .openai || provider == .groq || provider == .zai || provider == .qwen || provider == .openrouter
                    || (provider == .custom && !Self.customEndpointRejectsTools)

                if includeTools && providerSupportsTools {
                    let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                    let toolsData: Data = await MainActor.run {
                        let tools = ToolDeclarations.openAITools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: self.nativeToolRouter?.mcpClient)
                        return (try? JSONSerialization.data(withJSONObject: tools)) ?? Data()
                    }
                    let tools = (try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? []
                    body["tools"] = tools
                }

                if onToken != nil {
                    body["stream"] = true
                    // Ask for a final usage chunk so the streamed path can record cost (Plan AU).
                    // Servers that don't support it ignore the field; we then simply record nothing.
                    body["stream_options"] = ["include_usage": true]
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 60 // 60s timeout to prevent app freezing

                // Debug: log request details (redact base64 images)
                let messageCount = (body["messages"] as? [[String: Any]])?.count ?? 0
                let hasImage = imageData != nil && supportsVision
                let bodySize = request.httpBody?.count ?? 0
                print("🌐 \(provider.displayName) request: model=\(config.model) url=\(baseURL) messages=\(messageCount) hasImage=\(hasImage) bodySize=\(bodySize)")

                // Final-reply turns stream into the Chat tab when a streaming caller passes `onToken`;
                // the reconstructed `message` (content + tool_calls) feeds the shared tool loop unchanged.
                let message: [String: Any]
                // Retry-without-tools for `.custom` (some Ollama/LM Studio builds 400 on the
                // `tools` array): strip it, remember for the session, and re-send once.
                func retryRequestWithoutTools() throws -> URLRequest {
                    NSLog("[LLMService] custom endpoint rejected tools payload — retrying without tools")
                    Self.customEndpointRejectsTools = true
                    body.removeValue(forKey: "tools")
                    var retried = request
                    retried.httpBody = try JSONSerialization.data(withJSONObject: body)
                    return retried
                }
                let toolsAttached = body["tools"] != nil

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
                        message = try await streamTurn(request)
                    } catch LLMError.apiError(_, 400, _) where provider == .custom && toolsAttached {
                        message = try await streamTurn(try retryRequestWithoutTools())
                    }
                } else {
                    var (data, response) = try await URLSession.shared.data(for: request)
                    if provider == .custom, toolsAttached,
                       (response as? HTTPURLResponse)?.statusCode == 400 {
                        (data, response) = try await URLSession.shared.data(for: try retryRequestWithoutTools())
                    }

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let rawBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                        print("❌ \(provider.displayName) raw error response (\(statusCode)): \(rawBody.prefix(500))")
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorObj = errorJson["error"] as? [String: Any],
                           let errorMsg = errorObj["message"] as? String {
                            print("❌ \(provider.displayName) API error \(statusCode): \(errorMsg)")
                            throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: errorMsg)
                        }
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let errorMsg = errorJson["error"] as? String {
                            print("❌ \(provider.displayName) error \(statusCode): \(errorMsg)")
                            throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: errorMsg)
                        }
                        throw LLMError.apiError(provider: provider.displayName, statusCode: statusCode, message: nil)
                    }

                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let m = choices.first?["message"] as? [String: Any] else {
                        throw LLMError.invalidResponse(provider.displayName)
                    }
                    message = m
                    self.recordUsage(provider: provider, model: config.model, json: json)
                }

                var toolCalls: [ToolInvocation] = []
                if includeTools, let calls = message["tool_calls"] as? [[String: Any]] {
                    for (index, toolCall) in calls.enumerated() {
                        // Only `function.name` is truly required. Gemini's OpenAI-compatible
                        // endpoint can omit `id` and `arguments` (no-arg tools) — the old strict
                        // guard silently DROPPED such calls, so the loop finalized with an empty
                        // reply while the server had returned a perfectly good tool_call.
                        guard let function = toolCall["function"] as? [String: Any],
                              let functionName = function["name"] as? String else {
                            NSLog("[LLMService] Dropping malformed tool_call (no function.name): %@",
                                  String(String(describing: toolCall).prefix(200)))
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
                    NSLog("[LLMService] %@ turn: %d/%d tool call(s) parsed%@", provider.displayName,
                          toolCalls.count, calls.count,
                          toolCalls.isEmpty ? "" : " → " + toolCalls.map(\.name).joined(separator: ", "))
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
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(toolName: outcome.invocation.name, content: resultContent)
                    self.conversationHistory.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": framed
                    ])
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

        return try await runToolLoop(maxIterations: maxToolCallIterations, adapter: adapter,
                                     setStatus: { [weak self] in self?.toolCallStatus = $0 })
    }

    // MARK: - ChatGPT subscription (Responses backend, Plan BW P3)

    /// Send via the ChatGPT subscription provider: bearer OAuth token + account-id header
    /// against the Responses backend. History stays in the chat shape (`ResponsesTranslator`
    /// converts to Responses items at request time), so history hygiene, pruning, and
    /// persistence behave exactly like the OpenAI-compatible path.
    private func sendChatGPT(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?, onToken: ((String) -> Void)? = nil, onStreamReset: (() -> Void)? = nil) async throws -> String {
        guard let token = await ChatGPTOAuthService.shared.validAccessToken() else {
            throw LLMError.missingAPIKey("ChatGPT account not connected — sign in with ChatGPT in the model editor")
        }
        let accountID = ChatGPTOAuthService.shared.accountID
        let endpoint = config.baseURL.isEmpty ? ChatGPTOAuth.backendResponsesURL : config.baseURL
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Invalid ChatGPT backend URL: \(endpoint)")
        }

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
        trimHistory()

        var chatTools: [[String: Any]]?
        if includeTools {
            let includeOpenClaw = Config.isOpenClawAgentActive && openClawBridge != nil
            chatTools = ToolDeclarations.openAITools(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: nativeToolRouter?.mcpClient)
        }
        let tools = chatTools

        let adapter = ProviderLoopAdapter(
            label: "ChatGPT",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("ChatGPT") }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                ChatGPTAuth.apply(credential: token, accountID: accountID, to: &request)
                let streaming = onToken != nil
                let body = ResponsesTranslator.requestBody(
                    model: config.model, instructions: systemPrompt,
                    history: self.conversationHistory, tools: tools, stream: streaming)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.timeoutInterval = 120

                let responseJSON: [String: Any]
                if streaming, let onToken {
                    // New tool-loop iteration: clear the caller's accumulated bubble first (BM P9).
                    onStreamReset?()
                    responseJSON = try await self.streamResponsesTurn(request: request, onToken: onToken)
                } else {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        let bodyText = String(data: data, encoding: .utf8) ?? ""
                        NSLog("[LLMService] ChatGPT backend error %d: %@", status, String(bodyText.prefix(300)))
                        throw LLMError.apiError(provider: "ChatGPT", statusCode: status, message: String(bodyText.prefix(300)))
                    }
                    responseJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                }

                let parsed = ResponsesTranslator.parseOutput(responseJSON)
                // The parse-vs-sent diagnostic seam — where "tool_call returned but nothing
                // executed" bugs get caught.
                NSLog("[LLMService] ChatGPT turn: %d tool call(s) parsed%@", parsed.toolCalls.count,
                      parsed.toolCalls.isEmpty ? "" : " → " + parsed.toolCalls.map(\.name).joined(separator: ", "))
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
                    // Frame untrusted external content as data, not instructions.
                    let framed = self.wrapToolResultForModel(toolName: outcome.invocation.name, content: resultContent)
                    self.conversationHistory.append(["role": "tool", "tool_call_id": callId, "content": framed])
                }
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse("ChatGPT") }
                // Lenient like the other paths — an empty final text is appended, not thrown.
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                return turn.text
            }
        )
        return try await runToolLoop(maxIterations: maxToolCallIterations, adapter: adapter,
                                     setStatus: { [weak self] in self?.toolCallStatus = $0 })
    }

    /// One streamed Responses turn: SSE events → `onToken` text deltas; returns the
    /// authoritative `response.completed` payload (a shed delta is cosmetic, never corrupting).
    /// Events are fed to the parser only at blank-line boundaries so a network chunk can't
    /// shear a multi-byte character or a JSON payload.
    private func streamResponsesTurn(request: URLRequest, onToken: @escaping (String) -> Void) async throws -> [String: Any] {
        let (bytes, response) = try await streamingSession.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count > 2048 { break }
            }
            let text = String(data: errorBody, encoding: .utf8) ?? ""
            throw LLMError.apiError(provider: "ChatGPT", statusCode: status, message: String(text.prefix(300)))
        }

        var parser = SSEEventParser()
        var accumulator = ResponsesTranslator.StreamAccumulator()
        var buffer = Data()

        func feed(_ chunk: String, flush: Bool = false) {
            var events = parser.consume(chunk)
            if flush { events += parser.flush() }
            for event in events {
                if let delta = accumulator.consume(event) { onToken(delta) }
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
            throw LLMError.apiError(provider: "ChatGPT", statusCode: 200, message: failure)
        }
        guard let completed = accumulator.completedResponse else {
            throw LLMError.invalidResponse("ChatGPT (stream ended without completion)")
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
        guard let token = await ChatGPTOAuthService.shared.validAccessToken(),
              let url = URL(string: ChatGPTOAuth.backendResponsesURL) else { return nil }
        var body = ResponsesTranslator.requestBody(
            model: model, instructions: instructions,
            history: [["role": "user", "content": userContent]], tools: nil, stream: false)
        if let responseTools {
            body["tools"] = responseTools
            if let forcedToolName {
                body["tool_choice"] = ["type": "function", "name": forcedToolName]
            }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        ChatGPTAuth.apply(credential: token, accountID: ChatGPTOAuthService.shared.accountID, to: &request)
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
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
        case LLMError.apiError(_, let status, _):
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
                print("🔁 SSE transient failure (attempt \(failures)) — retrying in \(delay)s: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Stream an OpenAI-compatible chat-completions response, invoking `onToken` for each text
    /// delta, and return a reconstructed `message` dict (same shape as `choices[].message`) so the
    /// caller's tool loop runs identically to the buffered path. Only used when a streaming caller
    /// (the Chat tab) passes `onToken`; every other caller keeps the buffered path.
    func streamOpenAIMessage(request: URLRequest, provider: LLMProvider, model: String, onToken: @escaping (String) -> Void) async throws -> [String: Any] {
        let (bytes, response) = try await streamingSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse(provider.displayName) }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let raw = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            print("❌ \(provider.displayName) stream error \(http.statusCode): \(raw.prefix(300))")
            throw LLMError.apiError(provider: provider.displayName, statusCode: http.statusCode, message: msg)
        }

        var fullContent = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]  // tool_calls accumulate by index
        var usage = StreamingUsageAccumulator()   // from the final include_usage chunk
        var sawDone = false

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
            guard let choice = (obj["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                fullContent += chunk
                onToken(chunk)
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

        var message: [String: Any] = ["role": "assistant", "content": fullContent]
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
        let (bytes, response) = try await streamingSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("Anthropic") }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw LLMError.apiError(provider: "Anthropic", statusCode: http.statusCode, message: msg)
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
                    if (cb["type"] as? String) == "tool_use" { toolJSON[idx] = "" }
                }
            case "content_block_delta":
                let idx = obj["index"] as? Int ?? 0
                if let delta = obj["delta"] as? [String: Any], let dtype = delta["type"] as? String {
                    if dtype == "text_delta", let t = delta["text"] as? String {
                        var b = blocks[idx] ?? ["type": "text", "text": ""]
                        b["text"] = ((b["text"] as? String) ?? "") + t
                        blocks[idx] = b
                        onToken(t)
                    } else if dtype == "input_json_delta", let pj = delta["partial_json"] as? String {
                        toolJSON[idx, default: ""] += pj
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
        var request: URLRequest
        switch config.llmProvider {
        case .geminiVertex:
            guard let endpoint = VertexAI.endpointURL(
                projectID: Config.vertexProjectID, region: Config.vertexRegion, model: config.model) else {
                throw LLMError.invalidConfiguration("Vertex AI needs a GCP project ID and region — set them in the model editor.")
            }
            guard let token = await GoogleOAuthService.shared.validAccessToken() else {
                throw LLMError.missingAPIKey("Google account not connected — sign in with Google in the model editor.")
            }
            request = URLRequest(url: endpoint)
            VertexAI.apply(accessToken: token, to: &request)
        default:
            guard !config.apiKey.isEmpty else {
                throw LLMError.missingAPIKey("Gemini API key not configured")
            }
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent?key=\(config.apiKey)") else {
                throw LLMError.invalidConfiguration("Invalid Gemini URL")
            }
            request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    private func sendGemini(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
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

        let adapter = ProviderLoopAdapter(
            label: "Gemini",
            dispatcher: makeToolDispatcher(),
            performTurn: { [weak self] in
                guard let self else { throw LLMError.invalidResponse("Gemini") }
                // Re-resolve endpoint + auth per turn — a Vertex token refreshed mid-tool-loop
                // is picked up; AI Studio resolves to the same keyed URL every time.
                var request = try await self.geminiRequest(for: config)

                // Gemini format: system instruction + contents array
                var contents: [[String: Any]] = []
                for msg in self.conversationHistory {
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

                var body: [String: Any] = [
                    "system_instruction": ["parts": [["text": systemPrompt]]],
                    "contents": contents,
                    // CO Item 2: a bounded thinking budget on the tool turn, and an allowance that
                    // covers thinking *plus* the answer. Without this, reasoning and reply compete
                    // for the same 1024 tokens and the turn can come back empty with a STOP finish.
                    "generationConfig": GeminiBudgetPolicy.generationConfig(
                        includesTools: includeTools, configuredMaxTokens: Config.maxTokens)
                ]

                if includeTools {
                    let includeOpenClaw = Config.isOpenClawAgentActive && self.openClawBridge != nil
                    let toolsData: Data = await MainActor.run {
                        let tools = ToolDeclarations.geminiRESTTools(registry: self.nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw, mcpClient: self.nativeToolRouter?.mcpClient)
                        return (try? JSONSerialization.data(withJSONObject: tools)) ?? Data()
                    }
                    let tools = (try? JSONSerialization.jsonObject(with: toolsData)) as? [[String: Any]] ?? []
                    body["tools"] = tools
                }

                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorObj = errorJson["error"] as? [String: Any],
                       let errorMsg = errorObj["message"] as? String {
                        print("❌ Gemini API error \(statusCode): \(errorMsg)")
                        throw LLMError.apiError(provider: "Gemini", statusCode: statusCode, message: errorMsg)
                    }
                    throw LLMError.apiError(provider: "Gemini", statusCode: statusCode, message: nil)
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    throw LLMError.invalidResponse("Gemini")
                }
                self.recordUsage(provider: .gemini, model: config.model, json: json)

                var toolCalls: [ToolInvocation] = []
                if includeTools {
                    for part in parts where part["functionCall"] != nil {
                        guard let funcCall = part["functionCall"] as? [String: Any],
                              let name = funcCall["name"] as? String,
                              let args = funcCall["args"] as? [String: Any] else { continue }
                        toolCalls.append(ToolInvocation(id: nil, name: name, arguments: args))
                    }
                }
                let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
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
                for outcome in outcomes {
                    let name = outcome.invocation.name
                    let resultContent: [String: Any]
                    switch outcome.result {
                    case .success(let text):
                        // Frame untrusted external content as data, not instructions.
                        resultContent = ["result": self.wrapToolResultForModel(toolName: name, content: text)]
                    case .failure(let error):
                        resultContent = ["error": error]
                    }
                    functionResponseParts.append([
                        "functionResponse": ["name": name, "response": resultContent]
                    ])
                }
                self.conversationHistory.append(["role": "function", "parts": functionResponseParts])
            },
            finalize: { [weak self] turn in
                guard let self else { throw LLMError.invalidResponse("Gemini") }
                guard !turn.text.isEmpty else {
                    // CO Item 2: an empty completion is classified `retryOtherModel`, so the
                    // cascade silently rescues the turn and the user never notices. Good
                    // behaviour, terrible observability — a systematic defect (an unbounded
                    // thinking pass eating the whole allowance) would read as ordinary model
                    // churn. Mark it distinctly on the way past so it can be found in a log.
                    NSLog("[CO-EmptyCompletion] Gemini returned zero output tokens on a %@ turn — "
                          + "cascading. If this repeats, suspect the thinking/answer budget split.",
                          includeTools ? "tool" : "plain")
                    throw LLMError.invalidResponse("Gemini")
                }
                self.conversationHistory.append(["role": "assistant", "content": turn.text])
                return turn.text
            }
        )

        return try await runToolLoop(maxIterations: maxToolCallIterations, adapter: adapter,
                                     setStatus: { [weak self] in self?.toolCallStatus = $0 })
    }

    // MARK: - Local (On-Device MLX)

    // MARK: - Apple Foundation Models (On-Device)

    private func sendAppleOnDevice(_ text: String, systemPrompt: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw LLMError.missingAPIKey("Apple Intelligence requires iOS 26+")
        }
        return try await sendAppleOnDeviceImpl(text, systemPrompt: systemPrompt)
        #else
        throw LLMError.missingAPIKey("Apple Foundation Models requires iOS 26+")
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func sendAppleOnDeviceImpl(_ text: String, systemPrompt: String) async throws -> String {
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            switch availability {
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    throw LLMError.missingAPIKey("Device does not support Apple Intelligence")
                case .appleIntelligenceNotEnabled:
                    throw LLMError.missingAPIKey("Enable Apple Intelligence in Settings > Apple Intelligence & Siri")
                case .modelNotReady:
                    throw LLMError.missingAPIKey("Apple Intelligence model is still downloading, try again later")
                @unknown default:
                    throw LLMError.missingAPIKey("Apple Intelligence unavailable")
                }
            default:
                throw LLMError.missingAPIKey("Apple Intelligence unavailable")
            }
        }

        if appleSession == nil {
            appleSession = LanguageModelSession(instructions: systemPrompt)
        }

        let session = appleSession!
        let response = try await session.respond(to: text)

        // Uncertainty gate (Plan BI): no tool channel is wired on the Apple on-device path, so a
        // hedged or freshness-sensitive answer gets one transparent web-grounded re-ask.
        var answer = response.content
        if Config.localWebSearchFallbackEnabled,
           UncertaintyDetector.assess(question: text, answer: answer).shouldSearch {
            // The Apple session is stateful (it holds its own transcript), so its rewrite is
            // context-aware without an explicit history block; the shared conversationHistory
            // still feeds the grounding prompt for cross-answer reconciliation.
            let recent = recentTupleHistory(6, stripToolMarkup: false)
            answer = await UncertaintyReask.answer(
                question: text,
                originalAnswer: answer,
                history: recent,
                search: { query in try await WebSearchTool().execute(args: ["query": query]) },
                rewriteQuery: { q in
                    try await session.respond(to: "Rewrite this follow-up as ONE self-contained web search query, using our conversation for context. If it already stands alone, output it unchanged. Output only the query, nothing else: \(q)").content
                },
                regenerate: { grounding in try await session.respond(to: grounding).content }
            )
        }
        return answer
    }
    #endif

    /// The reduced tool set a local model is offered — only simple, reliable, self-contained tools
    /// (each resolves its own inputs, e.g. `get_weather`/`where_am_i` read LocationService directly,
    /// so the 2B model never has to supply coordinates it doesn't have).
    nonisolated static let localSafeTools: Set<String> = [
        "get_weather", "get_datetime", "calculate", "set_timer",
        "flashlight", "brightness", "calendar", "reminder",
        "set_alarm", "step_count", "device_info", "music_control",
        "where_am_i"
    ]

    /// Record an exchange the LLM didn't produce — tier-0 direct tool answers — so
    /// follow-up turns can see it. Without this, "what about tomorrow?" after a direct
    /// weather answer reached the model with no forecast anywhere in its history (the
    /// direct path bypasses the LLM entirely; it only wrote to the UI transcript).
    func recordExternalExchange(user: String, assistant: String) {
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

    /// Parse the local model's `<tool_call>` markup. Extracted (pure) from `sendLocal` so
    /// the announce-without-action retry can re-parse the corrective generation.
    nonisolated static func parseLocalToolCall(_ response: String) -> (name: String, args: [String: Any])? {
        let pattern = #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
              let jsonRange = Range(match.range(at: 1), in: response),
              let data = String(response[jsonRange]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              let args = object["arguments"] as? [String: Any] else {
            return nil
        }
        return (name, args)
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
                content = content
                    .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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

    // Unlike the cloud providers, the on-device path is deliberately NOT on the shared `runToolLoop`
    // driver (Plan BG P3). On-device models don't expose a structured tool-use API — they emit
    // `<tool_call>` markup — so this path is single-shot with a reduced tool set and one optional
    // re-generation, not an iterate-until-done loop. Routing it through the iterative driver would
    // change its behaviour, which the refactor explicitly avoids.
    private func sendLocal(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data? = nil, onToken: ((String) -> Void)? = nil) async throws -> String {
        guard let localService = localLLMService else {
            throw LLMError.missingAPIKey("Local LLM service not initialized")
        }

        // Load the configured model (no auto-swap — user picks one model)
        if !localService.isModelLoaded || localService.loadedModelId != config.model {
            try await localService.loadModel(config.model)
        }

        // Build tool instructions — use minimal set for local models
        var fullPrompt = systemPrompt
        if includeTools, let router = nativeToolRouter {
            let toolNames = router.registry.toolNames.filter { Self.localSafeTools.contains($0) }
            fullPrompt += Self.localToolInstructions(toolNames: toolNames)
        }

        // Build history — last 3 exchanges for local models (context is precious; the
        // LocalModelBudget cap still guards the ceiling). Was 2 — too short for a
        // follow-up that references the answer before last.
        let history = recentTupleHistory(6, stripToolMarkup: true)

        // Add user message to history
        conversationHistory.append(["role": "user", "content": text])
        trimHistory()

        // Generate response. Stream tokens to the UI as they're produced. In the (rare, the local
        // tool prompt says "use sparingly") case where the model emits a <tool_call>, the preview
        // briefly shows the markup before the cleaned final reply replaces it — acceptable for the
        // common no-tool path, which streams cleanly.
        var response: String
        do {
            // The image rides only the FIRST generation of the turn — tool-result follow-up
            // regenerations below re-answer over text, which is correct and far cheaper.
            response = try await localService.generate(
                userMessage: text,
                systemPrompt: fullPrompt,
                history: history,
                imageData: imageData,
                onToken: onToken
            )
        } catch is CancellationError {
            // BK P4: a barge-in cancels the local generation. Propagate CancellationError UNWRAPPED
            // so ConversationTurnRunner maps it to onCancelled (partial reply not spoken) instead
            // of onError. Wrapping it in LLMError here would speak the generic error line.
            throw CancellationError()
        } catch let error as LocalLLMError {
            // Propagate .backgrounded unwrapped so callers (e.g. AgentScheduler) can
            // tell "can't run on-device in background" apart from a real failure and
            // defer rather than consuming the scheduled run.
            print("❌ Local model generation failed: \(error)")
            throw error
        } catch {
            print("❌ Local model generation failed: \(error)")
            throw LLMError.invalidResponse("Local model error: \(error.localizedDescription)")
        }

        // Try to parse tool calls — but don't crash if the model doesn't support them well.
        var parsedCall = Self.parseLocalToolCall(response)

        // Announce-without-action (live-traced failure): the model says "I'm looking that
        // up" without emitting the tool_call markup, and the single-shot path would accept
        // the announcement as the answer. One corrective re-generation demanding the call
        // (or a direct answer) — bounded, never loops.
        if parsedCall == nil, includeTools, nativeToolRouter != nil,
           Self.announcesToolIntent(response) || Self.asksUserForLocation(response) {
            print("🔁 Local model stalled (announcement/location ask-back) — corrective regen")
            let correction = Self.asksUserForLocation(response)
                ? "The user's location is already available to you — never ask for it. Call the where_am_i or get_weather tool now via <tool_call> in the exact format, then answer."
                : "You said you would look that up, but you did not call a tool. Either output the <tool_call> now in the exact format, or answer directly. Never say you will check — act."
            var correctiveHistory = history
            correctiveHistory.append((role: "assistant", content: response))
            correctiveHistory.append((role: "user", content: correction))
            if let second = try? await localService.generate(
                userMessage: correction,
                systemPrompt: fullPrompt,
                history: correctiveHistory
            ) {
                response = second
                parsedCall = Self.parseLocalToolCall(response)
            }
        }

        if let (toolName, toolArgs) = parsedCall,
           let router = nativeToolRouter {

            // Execute the tool
            print("🔧 Local model tool call: \(toolName)(\(toolArgs))")
            toolCallStatus = .executing(toolName)
            let result = await router.handleToolCall(name: toolName, args: toolArgs)
            toolCallStatus = .idle

            let resultText: String
            switch result {
            case .success(let text): resultText = text
            case .failure(let error): resultText = "Error: \(error)"
            }

            // Get the text before the tool call as context
            let textBefore = response
                .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to re-generate with tool result for a natural response
            var updatedHistory = history
            updatedHistory.append((role: "assistant", content: textBefore.isEmpty ? "Let me check that for you." : textBefore))
            updatedHistory.append((role: "user", content: "Tool '\(toolName)' returned: \(resultText). Please respond naturally to the user based on this result."))

            let finalResponse: String
            do {
                finalResponse = try await localService.generate(
                    userMessage: "Respond to the user based on the tool result above.",
                    systemPrompt: fullPrompt,
                    history: updatedHistory
                )
            } catch is CancellationError {
                throw CancellationError()   // BK P4: a barge-in during the tool-result regen cancels too
            } catch {
                // If re-generation fails, just return the tool result directly
                finalResponse = textBefore.isEmpty ? resultText : "\(textBefore) \(resultText)"
            }

            // BK P3: an all-markup / empty final (e.g. the model answers the tool result with
            // another <tool_call>) must surface as an error, not silent dead air at the speaker.
            let cleanFinal = try Self.cleanedNonEmptyLocalAnswer(finalResponse)
            conversationHistory.append(["role": "assistant", "content": cleanFinal])
            trimHistory()
            return cleanFinal
        }

        // No tool call — clean up any partial tool markup and return
        let cleanResponse = response
            .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        if Config.localWebSearchFallbackEnabled, !isPersonalData,
           announcedIntent || UncertaintyDetector.assess(question: text, answer: cleanResponse).shouldSearch {
            finalAnswer = await UncertaintyReask.answer(
                question: text,
                originalAnswer: cleanResponse,
                history: history,
                search: { query in try await WebSearchTool().execute(args: ["query": query]) },
                rewriteQuery: { q in
                    // A follow-up leaning on the conversation ("the other semi final?") is a
                    // junk literal query — one tiny generation makes it self-contained.
                    try await localService.generate(
                        userMessage: "Conversation:\n\(UncertaintyReask.conversationBlock(history: history))\n\nRewrite this follow-up as ONE self-contained web search query. If it already stands alone, output it unchanged. Output only the query, nothing else: \(q)",
                        systemPrompt: "You rewrite follow-up questions into standalone web search queries. Output only the query."
                    )
                },
                regenerate: { grounding in
                    try await localService.generate(
                        userMessage: grounding,
                        systemPrompt: fullPrompt,
                        history: history
                    )
                }
            )
        }

        // The never-speak-a-promise net: if the answer still announces an action (re-ask failed
        // or the fallback flag is off), replace it with an honest miss.
        if announcedIntent && finalAnswer == cleanResponse {
            finalAnswer = "I couldn't get that information just now — please ask me again."
        }

        // BK P3: reject an empty local completion (immediate EOS / all-markup) instead of
        // speaking silence — matches the Anthropic/Gemini empty-completion guards.
        let validated = try Self.cleanedNonEmptyLocalAnswer(finalAnswer)
        conversationHistory.append(["role": "assistant", "content": validated])
        trimHistory()
        return validated
    }

    // MARK: - Local Agent Model

    /// Send a message through the on-device agent model (Gemma 4 via MLX).
    /// Used for fast-tier queries when agentic mode is enabled.
    /// Builds its own lightweight prompt and routes through sendLocal().
    func sendViaLocalAgent(_ text: String, locationContext: String? = nil, memoryContext: String? = nil, weatherContext: String? = nil) async throws -> String {
        let agentModelId = Config.agentModelId
        let hasNativeTools = nativeToolRouter != nil

        // Cloud agent: build the full tool-laden system prompt — cloud models handle a large
        // context and tool-call natively.
        if let cloudConfig = Config.savedModels.first(where: { $0.id == agentModelId }) {
            let nativeToolNames = nativeToolRouter?.registry.toolNames ?? []
            let nativeToolDescriptions = nativeToolRouter?.registry.toolDescriptions(for: nativeToolNames) ?? []
            let fullPrompt = await Self.buildSystemPrompt(
                locationContext: locationContext,
                includeTools: hasNativeTools,
                includeOpenClaw: false,
                hasImage: false,
                nativeToolNames: nativeToolNames,
                nativeToolDescriptions: nativeToolDescriptions,
                memoryContext: memoryContext,
                turn: text
            )
            print("🧠 Cloud agent: \(cloudConfig.name)")
            return try await sendCloud(text, systemPrompt: fullPrompt, config: cloudConfig, includeTools: hasNativeTools)
        }

        // On-device agent: build a LEAN prompt (shared with the active-model path) — omits the
        // ~100 native-tool descriptions (~8k tokens) that OOM-crash a 2B model on a phone.
        // `sendLocal` appends its own reduced ~12-tool block, so the model still has usable tools.
        guard let localService = localLLMService else {
            throw LLMError.missingAPIKey("Local LLM service not initialized")
        }
        let leanPrompt = await Self.leanOnDevicePrompt(
            locationContext: locationContext, memoryContext: memoryContext, hasImage: false, turn: text,
            weatherContext: weatherContext)
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
        print("🧠 Local agent: \(agentModelId)")
        return try await sendLocal(text, systemPrompt: leanPrompt, config: localConfig, includeTools: hasNativeTools)
    }

    // MARK: - Helpers

    /// Trim history only when token budget is exceeded — no fixed turn limit.
    /// Preserves recent context and any messages containing memory commands or important decisions.
    private func trimHistory() {
        compressContextWindowIfNeeded()
    }

    /// Inject a hidden system message into conversation history.
    /// Used by the memory nudge to prompt periodic review without the user seeing it.
    func injectSystemMessage(_ message: String) {
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
    nonisolated static func cleanedNonEmptyLocalAnswer(_ raw: String) throws -> String {
        let cleaned = raw
            .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
            // A small model fed a merged (no-system-role) prompt can answer in transcript
            // style — "OpenGlasses: ..." / "Assistant: ..." — and TTS would speak the label.
            .replacingOccurrences(of: #"^\s*(OpenGlasses|Assistant|AI|Model)\s*:\s*"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LLMError.invalidResponse("Local") }
        return cleaned
    }

    static func stripThinkTags(_ text: String) -> (spoken: String, reasoning: String?) {
        // Template-opened reasoning (LFM-style chat templates emit the opening <think> as
        // part of the generation prompt): the completion carries a bare </think> with no
        // opener. Re-open so the paired-tag pass below handles both shapes.
        var text = text
        if let close = text.range(of: "</think>"),
           text[..<close.lowerBound].range(of: "<think>") == nil {
            text = "<think>" + text
        }
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, nil)
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return (text, nil) }

        // Extract all reasoning blocks
        let reasoning = matches.compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            var block = String(text[matchRange])
            block = block.replacingOccurrences(of: "<think>", with: "")
            block = block.replacingOccurrences(of: "</think>", with: "")
            return block.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")

        // Remove think tags from the spoken output
        let spoken = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (spoken, reasoning.isEmpty ? nil : reasoning)
    }
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse(String)
    case invalidConfiguration(String)
    case apiError(provider: String, statusCode: Int, message: String?)
    /// A streaming response died mid-flight — a mid-stream `error` event or a connection that
    /// ended before the terminator (`[DONE]` / `message_stop`). Partial content must never be
    /// returned as a successful turn (BM P9).
    case streamInterrupted(provider: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        case .invalidResponse(let provider): return "Invalid response from \(provider)"
        case .invalidConfiguration(let msg): return msg
        case .apiError(let provider, let code, let msg):
            if let msg { return "\(provider) error \(code): \(msg)" }
            return "\(provider) error: \(code)"
        case .streamInterrupted(let provider, let reason):
            return "\(provider) stream interrupted: \(reason)"
        }
    }
}

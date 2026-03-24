import Foundation

/// Supported LLM providers
enum LLMProvider: String, CaseIterable {
    case anthropic = "anthropic"
    case openai = "openai"
    case gemini = "gemini"
    case groq = "groq"
    case zai = "zai"
    case qwen = "qwen"
    case minimax = "minimax"
    case openrouter = "openrouter"
    case custom = "custom"
    case local = "local"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (GPT)"
        case .gemini: return "Google (Gemini)"
        case .groq: return "Groq"
        case .zai: return "Z.ai (Subscription)"
        case .qwen: return "Qwen (Coding Plan subscription)"
        case .minimax: return "MiniMax (Subscription)"
        case .openrouter: return "OpenRouter (500+ models)"
        case .custom: return "Custom (OpenAI-compatible)"
        case .local: return "Local (On-Device)"
        }
    }

    /// Whether this provider uses the OpenAI-compatible API format
    var isOpenAICompatible: Bool {
        switch self {
        case .anthropic, .gemini, .local: return false
        case .openai, .groq, .zai, .qwen, .minimax, .openrouter, .custom: return true
        }
    }

    /// Default base URL for the provider
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .groq: return "https://api.groq.com/openai/v1/chat/completions"
        case .zai: return "https://api.z.ai/api/coding/paas/v4/chat/completions"
        case .qwen: return "https://coding-intl.dashscope.aliyuncs.com/v1/chat/completions"
        case .minimax: return "https://api.minimaxi.chat/v1/text/chatcompletion_v2"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .custom: return "https://api.openai.com/v1/chat/completions"
        case .local: return ""
        }
    }

    /// Default model for the provider
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.0-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .zai: return "glm-4.5"
        case .qwen: return "qwen3.5-plus"
        case .minimax: return "MiniMax-Text-01"
        case .openrouter: return "anthropic/claude-sonnet-4"
        case .custom: return "gpt-4o"
        case .local: return "mlx-community/gemma-2-2b-it-4bit"
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
        case .local: return false
        default: return true
        }
    }

    /// Whether this provider supports listing models via API
    var supportsModelListing: Bool {
        switch self {
        case .local: return false
        default: return true
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

    /// Optional OpenClaw bridge for tool calling in direct mode
    var openClawBridge: OpenClawBridge?

    /// Native tool router — when set, enables built-in tools (weather, timer, etc.)
    var nativeToolRouter: NativeToolRouter?

    /// Local on-device LLM service (MLX Swift)
    var localLLMService: LocalLLMService?

    /// Conversation history for multi-turn context
    private var conversationHistory: [[String: Any]] = []
    private let maxHistoryTurns = 10  // Keep last 10 exchanges

    /// Maximum tool call iterations to prevent infinite loops
    private let maxToolCallIterations = 5

    /// Build the full system prompt, optionally including location, tools, memory, and vision context
    private static func buildSystemPrompt(locationContext: String?, includeTools: Bool, includeOpenClaw: Bool, hasImage: Bool, nativeToolNames: [String] = [], memoryContext: String? = nil, agentContext: String? = nil) -> String {
        // Agent personality mode: soul.md + skills.md + memory.md replace the standard prompt
        var prompt: String
        if Config.agentModeEnabled, let agentContext, !agentContext.isEmpty {
            prompt = agentContext
        } else {
            prompt = Config.systemPrompt
        }

        // Ensure vision awareness is always present, even if user has a custom system prompt
        if !prompt.lowercased().contains("vision") && !prompt.lowercased().contains("camera") {
            prompt += """

            VISION & CAMERA:
            - The glasses have a camera. When the user says "look at this", "what is this", "read this", "identify this", "take a photo", or similar, a photo will be captured and sent to you automatically.
            - You CAN see images — never say you lack camera or vision access.
            - For text/signs/menus in foreign languages: transcribe the original text, then translate it.
            - For objects, products, landmarks: identify and describe them.
            - After reading text from an image, offer to copy it to clipboard or translate it.
            """
        }

        if includeTools {
            var toolSection = """


            TOOLS:
            You have access to the following tools. Use the appropriate tool when the user's request matches its capability.
            """

            if !nativeToolNames.isEmpty {
                toolSection += "\nBuilt-in tools: \(nativeToolNames.joined(separator: ", "))."
                toolSection += """

            - get_weather: Get current weather and forecast.
            - get_datetime: Get current date, time, day of week.
            - daily_briefing: Combined daily briefing (date, weather, news) — use for "good morning" or "what's happening today".
            - calculate: Evaluate math expressions.
            - convert_units: Convert between units (length, weight, temp, volume, speed, etc).
            - set_timer: Set a countdown timer with local notification.
            - pomodoro: Start/stop/check a Pomodoro focus session (25 min work, 5 min break cycles).
            - save_note / list_notes: Save and retrieve notes locally.
            - web_search: Search the web via DuckDuckGo.
            - get_news: Get latest news headlines, optionally by topic.
            - translate: Translate text between languages.
            - define_word: Look up word definitions.
            - find_nearby: Search for nearby places (restaurants, cafes, pharmacies, gas stations, etc).
            - open_app: Open iOS apps (Music, Podcasts, Maps, Google Maps, YouTube, Spotify, etc).
            - get_directions: Directions via Apple Maps or Google Maps (set app='google' for Google Maps).
            - identify_song: Identify a song playing nearby using Shazam.
            - music_control: Play, pause, skip, previous track, or get now-playing info (Apple Music).
            - convert_currency: Convert between currencies with live exchange rates.
            - phone_call: Make a phone call to a number.
            - send_message: Open Messages with a pre-filled text to a recipient.
            - copy_to_clipboard: Copy text to clipboard (great after OCR, translation, or any result the user wants to keep).
            - flashlight: Turn the device flashlight on/off.
            - device_info: Check battery level, storage, and low power mode.
            - save_location / list_saved_locations: Save current spot with a label ("remember where I parked") and find saved spots later with distance.
            - step_count: Today's steps, walking distance, and floors climbed.
            - emergency_info: Local emergency numbers for current country, exact GPS coordinates, and guidance to find nearest hospital.
            - calendar: View today's schedule, next meeting, upcoming week, or create events. Events get a 15-min reminder notification.
            - lookup_contact: Look up a contact by name to get their phone number or email. Use before phone_call or send_message.
            - reminder: Create, list, or complete Apple Reminders with due dates and notifications. Syncs with iCloud.
            - set_alarm: Set an alarm for a specific clock time (e.g. '7 AM tomorrow'). Also list or cancel alarms.
            - brightness: Adjust screen brightness (0-100, or presets: max, min, dim, bright, up, down).
            - smart_home: Control HomeKit smart home devices — lights, switches, fans, thermostats, locks, scenes. Say 'list' to see devices.
            - run_shortcut: Run an Apple Shortcut by name (e.g. 'Start Focus', 'Log Water', any user-created shortcut).
            - summarize_conversation: Summarize current conversation, extract action items/to-dos. Use when user says "summarize", "recap", or "what did we discuss?"
            - face_recognition: Remember faces ('remember this person as John'), forget faces, list known people, or toggle auto-recognition on/off.
            - memory_rewind: Recall what was said recently. Transcribes last few minutes of ambient audio. Use for "what did they just say?" or "what happened?" Must be started first with action='start'.
            - geofence: Location-based reminders. 'Remind me when I get to the office' or 'alert me when I leave home'. Create, list, delete geofenced alerts.
            - send_via: Send messages via WhatsApp, Telegram, or Email. Specify channel ('whatsapp', 'telegram', 'email'), recipient, and body.
            - meeting_summary: Summarize a recent meeting or conversation from ambient captions. Extracts key points, decisions, and action items. Requires ambient captions to be running.
            - fitness_coach: Fitness coaching — start/stop workouts, log exercises (reps/sets/weight), check form via camera, get workout history from HealthKit, set step goals.
            - openclaw_skills: Discover and manage OpenClaw skills. List available skills, check gateway status, search for capabilities. Only available when OpenClaw is configured.
            - voice_skills: Voice-taught skills — save (teach a new trigger→action), list (show all), delete, clear. "Learn that when I say 'goodnight', turn off all lights."
            - object_memory: Remember where physical objects are. Save ('remember my keys are on the counter'), find ('where are my keys?'), list, forget.
            - contextual_note: Save notes with automatic location and time context. Search notes by keyword or location.
            - social_context: Remember facts about people. Add facts ('remember John works at Stripe'), recall ('what do I know about John?'), list people.
            - home_assistant: Control Home Assistant smart home — toggle devices, check states, list entities, run automations. Requires HA URL and token.
            - scan_code: Scan QR codes or barcodes from the camera. Returns decoded content (URLs, text, product codes). Works offline.
            - live_translate: Start/stop continuous live translation. Listens to spoken foreign language and translates in real-time. Actions: start, stop, status, set_language.
            """

                // Inject user-defined custom tool descriptions
                let customTools = Config.customTools.filter { Config.isToolEnabled($0.name) }
                for ct in customTools {
                    toolSection += "\n            - \(ct.name): \(ct.description)"
                }
            }

            if includeOpenClaw {
                toolSection += """

            You also have an "execute" tool for the OpenClaw personal assistant gateway. \
            Use it for actions built-in tools cannot handle: sending messages, managing calendar, \
            controlling smart home devices, complex research, or external integrations.
            """
            }

            toolSection += """

            TOOL USAGE RULES:
            1. Before calling any tool, ALWAYS speak a brief acknowledgment first. For example:
               - "Sure, let me check the weather." then call get_weather.
               - "Got it, searching for that now." then call web_search.
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
            Remember things like: their name, preferences, family members, routines, interests.
            Only remember when the user explicitly shares personal info — don't infer or assume.
            """
        }
        if let location = locationContext {
            prompt += "\n\nUSER LOCATION: \(location)"
        }
        // Inject voice-taught skills
        if let skills = VoiceSkillStore.shared.promptContext() {
            prompt += "\n\n\(skills)"
        }
        // Inject social context (people the user knows)
        if let social = SocialContextStore.shared.promptContext() {
            prompt += "\n\n\(social)"
        }
        return prompt
    }

    func sendMessage(_ text: String, locationContext: String? = nil, imageData: Data? = nil, memoryContext: String? = nil, agentContext: String? = nil) async throws -> String {
        isProcessing = true
        defer { isProcessing = false }

        guard let modelConfig = Config.activeModel else {
            throw LLMError.missingAPIKey("No model configured — add one in Settings")
        }

        let provider = modelConfig.llmProvider
        let hasNativeTools = nativeToolRouter != nil
        let includeOpenClaw = Config.isOpenClawConfigured && openClawBridge != nil
        let includeTools = hasNativeTools || includeOpenClaw
        let nativeToolNames = nativeToolRouter?.registry.toolNames ?? []
        let fullPrompt = Self.buildSystemPrompt(locationContext: locationContext, includeTools: includeTools, includeOpenClaw: includeOpenClaw, hasImage: imageData != nil, nativeToolNames: nativeToolNames, memoryContext: memoryContext, agentContext: agentContext)

        var toolsLabel = ""
        if hasNativeTools { toolsLabel += " [NativeTools]" }
        if includeOpenClaw { toolsLabel += " [OpenClaw]" }
        print("🤖 Using model: \(modelConfig.name) (\(modelConfig.model) via \(provider.displayName))\(toolsLabel)")

        switch provider {
        case .anthropic:
            return try await sendAnthropic(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .gemini:
            return try await sendGemini(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .local:
            return try await sendLocal(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        case .openai, .groq, .zai, .qwen, .minimax, .openrouter, .custom:
            return try await sendOpenAICompatible(text, systemPrompt: fullPrompt, config: modelConfig, includeTools: includeTools, imageData: imageData)
        }
    }

    /// Clear conversation history (e.g. when starting fresh or switching providers)
    func clearHistory() {
        conversationHistory.removeAll()
    }

    /// Refresh the published model name from Config
    func refreshActiveModel() {
        activeModelName = Config.activeModel?.name ?? "No Model"
    }

    // MARK: - Anthropic Claude

    private func sendAnthropic(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        let apiKey = config.apiKey
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("Anthropic API key not configured")
        }

        // Add user message to history
        if let imageData = imageData {
            let base64String = imageData.base64EncodedString()
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

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": includeTools ? 1024 : Config.maxTokens,
                "system": systemPrompt,
                "messages": conversationHistory
            ]

            if includeTools {
                let includeOpenClaw = Config.isOpenClawConfigured && openClawBridge != nil
                body["tools"] = await MainActor.run { ToolDeclarations.anthropicTools(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw) }
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                  let content = json["content"] as? [[String: Any]] else {
                throw LLMError.invalidResponse("Anthropic")
            }

            let stopReason = json["stop_reason"] as? String

            // Check for tool use blocks
            if stopReason == "tool_use", includeTools {
                // Find tool_use blocks
                var toolUseBlocks: [[String: Any]] = []
                var textParts: [String] = []

                for block in content {
                    if let type = block["type"] as? String {
                        if type == "tool_use" {
                            toolUseBlocks.append(block)
                        } else if type == "text", let t = block["text"] as? String {
                            textParts.append(t)
                        }
                    }
                }

                // Add assistant message with tool_use to history
                conversationHistory.append(["role": "assistant", "content": content] as [String: Any])

                // Execute each tool call via NativeToolRouter
                for toolUse in toolUseBlocks {
                    guard let toolId = toolUse["id"] as? String,
                          let toolName = toolUse["name"] as? String,
                          let input = toolUse["input"] as? [String: Any] else { continue }

                    print("🔧 [Anthropic] Tool call: \(toolName)(\(String(describing: input).prefix(100))...)")
                    toolCallStatus = .executing(toolName)

                    let result: ToolResult
                    if let router = nativeToolRouter {
                        result = await router.handleToolCall(name: toolName, args: input)
                    } else if let bridge = openClawBridge {
                        let taskDesc = input["task"] as? String ?? String(describing: input)
                        result = await bridge.delegateTask(task: taskDesc, toolName: toolName)
                    } else {
                        result = .failure("No tool handler available")
                    }
                    toolCallStatus = result.isSuccess ? .completed(toolName) : .failed(toolName, "Failed")

                    let resultContent: String
                    switch result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }

                    conversationHistory.append([
                        "role": "user",
                        "content": [
                            [
                                "type": "tool_result",
                                "tool_use_id": toolId,
                                "content": resultContent
                            ]
                        ]
                    ] as [String: Any])
                }

                print("🔄 [Anthropic] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No tool calls — extract text response
            let responseText = content.compactMap { block -> String? in
                guard let type = block["type"] as? String, type == "text",
                      let text = block["text"] as? String else { return nil }
                return text
            }.joined(separator: "\n")

            guard !responseText.isEmpty else {
                throw LLMError.invalidResponse("Anthropic")
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("Anthropic (tool call loop exceeded)")
    }

    // MARK: - OpenAI-compatible

    private func sendOpenAICompatible(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        let provider = config.llmProvider
        let apiKey = config.apiKey
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("\(provider.displayName) API key not configured")
        }

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
            let base64String = imageData.base64EncodedString()
            let content: [[String: Any]] = [
                [
                    "type": "text",
                    "text": text
                ],
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(base64String)"
                    ]
                ]
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

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            // OpenRouter requires additional headers for tracking
            if provider == .openrouter {
                request.setValue("https://github.com/straff2002/OpenGlasses", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("OpenGlasses", forHTTPHeaderField: "X-Title")
            }

            // OpenAI format: system prompt is a message in the array
            var messages: [[String: Any]] = [
                ["role": "system", "content": systemPrompt]
            ]
            messages.append(contentsOf: conversationHistory)

            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": includeTools ? 1024 : Config.maxTokens,
                "messages": messages
            ]

            // Only attach Tools if the provider reliably supports function calling.
            // Custom endpoints (Ollama/LMStudio) often crash with 400 if `tools` array is in the payload.
            let providerSupportsTools = provider == .openai || provider == .groq || provider == .zai || provider == .qwen || provider == .openrouter

            if includeTools && providerSupportsTools {
                let includeOpenClaw = Config.isOpenClawConfigured && openClawBridge != nil
                body["tools"] = await MainActor.run { ToolDeclarations.openAITools(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw) }
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Debug: log request details (redact base64 images)
            let debugBody = body.filter { $0.key != "messages" }
            print("🌐 \(provider.displayName) request: model=\(config.model) url=\(baseURL) keys=\(debugBody.keys.sorted())")

            let (data, response) = try await URLSession.shared.data(for: request)

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
                  let message = choices.first?["message"] as? [String: Any] else {
                throw LLMError.invalidResponse(provider.displayName)
            }

            _ = choices.first?["finish_reason"] as? String

            // Check for tool calls
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty, includeTools {
                // Add assistant message with tool_calls to history
                conversationHistory.append(message)

                for toolCall in toolCalls {
                    guard let callId = toolCall["id"] as? String,
                          let function = toolCall["function"] as? [String: Any],
                          let functionName = function["name"] as? String,
                          let argsString = function["arguments"] as? String else { continue }

                    let args = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any]) ?? [:]

                    print("🔧 [OpenAI] Tool call: \(functionName)(\(String(describing: args).prefix(100))...)")
                    toolCallStatus = .executing(functionName)

                    let result: ToolResult
                    if let router = nativeToolRouter {
                        result = await router.handleToolCall(name: functionName, args: args)
                    } else if let bridge = openClawBridge {
                        let taskDesc = args["task"] as? String ?? argsString
                        result = await bridge.delegateTask(task: taskDesc, toolName: functionName)
                    } else {
                        result = .failure("No tool handler available")
                    }
                    toolCallStatus = result.isSuccess ? .completed(functionName) : .failed(functionName, "Failed")

                    let resultContent: String
                    switch result {
                    case .success(let text): resultContent = text
                    case .failure(let error): resultContent = "Error: \(error)"
                    }

                    conversationHistory.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": resultContent
                    ])
                }

                print("🔄 [OpenAI] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No tool calls — extract text response
            guard let responseText = message["content"] as? String else {
                throw LLMError.invalidResponse(provider.displayName)
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("\(provider.displayName) (tool call loop exceeded)")
    }

    // MARK: - Google Gemini

    private func sendGemini(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data?) async throws -> String {
        let apiKey = config.apiKey
        guard !apiKey.isEmpty else {
            throw LLMError.missingAPIKey("Gemini API key not configured")
        }

        let model = config.model
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw LLMError.invalidConfiguration("Invalid Gemini URL")
        }

        // Add user message to history
        if let imageData = imageData {
            let base64String = imageData.base64EncodedString()
            let parts: [[String: Any]] = [
                ["text": text],
                ["inlineData": ["mimeType": "image/jpeg", "data": base64String]]
            ]
            conversationHistory.append(["role": "user", "parts": parts])
        } else {
            conversationHistory.append(["role": "user", "content": text])
        }
        trimHistory()

        for iteration in 0..<maxToolCallIterations {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            // Gemini format: system instruction + contents array
            var contents: [[String: Any]] = []
            for msg in conversationHistory {
                let role = msg["role"] as? String ?? "user"
                if role == "user" || role == "model" {
                    let geminiRole = role == "assistant" ? "model" : role
                    if let textContent = msg["content"] as? String {
                        contents.append([
                            "role": geminiRole,
                            "parts": [["text": textContent]]
                        ])
                    } else if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": geminiRole,
                            "parts": parts
                        ])
                    }
                } else if role == "assistant" {
                    if let textContent = msg["content"] as? String {
                        contents.append([
                            "role": "model",
                            "parts": [["text": textContent]]
                        ])
                    } else if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": "model",
                            "parts": parts
                        ])
                    }
                } else if role == "function" {
                    // Function response
                    if let parts = msg["parts"] as? [[String: Any]] {
                        contents.append([
                            "role": "user",
                            "parts": parts
                        ])
                    }
                }
            }

            var body: [String: Any] = [
                "system_instruction": [
                    "parts": [["text": systemPrompt]]
                ],
                "contents": contents,
                "generationConfig": [
                    "maxOutputTokens": includeTools ? 1024 : Config.maxTokens
                ]
            ]

            if includeTools {
                let includeOpenClaw = Config.isOpenClawConfigured && openClawBridge != nil
                body["tools"] = await MainActor.run { ToolDeclarations.geminiRESTTools(registry: nativeToolRouter?.registry, includeOpenClaw: includeOpenClaw) }
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

            // Check for function calls in parts
            let functionCallParts = parts.filter { $0["functionCall"] != nil }

            if !functionCallParts.isEmpty, includeTools {
                // Add model response with function call to history
                conversationHistory.append([
                    "role": "assistant",
                    "parts": parts
                ])

                var functionResponseParts: [[String: Any]] = []

                for part in functionCallParts {
                    guard let funcCall = part["functionCall"] as? [String: Any],
                          let name = funcCall["name"] as? String,
                          let args = funcCall["args"] as? [String: Any] else { continue }

                    print("🔧 [Gemini] Tool call: \(name)(\(String(describing: args).prefix(100))...)")
                    toolCallStatus = .executing(name)

                    let result: ToolResult
                    if let router = nativeToolRouter {
                        result = await router.handleToolCall(name: name, args: args)
                    } else if let bridge = openClawBridge {
                        let taskDesc = args["task"] as? String ?? String(describing: args)
                        result = await bridge.delegateTask(task: taskDesc, toolName: name)
                    } else {
                        result = .failure("No tool handler available")
                    }
                    toolCallStatus = result.isSuccess ? .completed(name) : .failed(name, "Failed")

                    let resultContent: [String: Any]
                    switch result {
                    case .success(let text): resultContent = ["result": text]
                    case .failure(let error): resultContent = ["error": error]
                    }

                    functionResponseParts.append([
                        "functionResponse": [
                            "name": name,
                            "response": resultContent
                        ]
                    ])
                }

                // Add function responses as user role
                conversationHistory.append([
                    "role": "function",
                    "parts": functionResponseParts
                ])

                print("🔄 [Gemini] Continuing after tool call (iteration \(iteration + 1))")
                continue // Loop back to get final response
            }

            // No function calls — extract text response
            let responseText = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")

            guard !responseText.isEmpty else {
                throw LLMError.invalidResponse("Gemini")
            }

            conversationHistory.append(["role": "assistant", "content": responseText])
            toolCallStatus = .idle
            return responseText
        }

        // Exhausted iterations
        toolCallStatus = .idle
        throw LLMError.invalidResponse("Gemini (tool call loop exceeded)")
    }

    // MARK: - Local (On-Device MLX)

    private func sendLocal(_ text: String, systemPrompt: String, config: ModelConfig, includeTools: Bool, imageData: Data? = nil) async throws -> String {
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
            // Local models get a reduced tool set — only simple, reliable tools
            let localSafeTools: Set<String> = [
                "get_weather", "get_datetime", "calculate", "set_timer",
                "flashlight", "brightness", "calendar", "reminder",
                "set_alarm", "step_count", "device_info", "music_control"
            ]
            let toolNames = router.registry.toolNames.filter { localSafeTools.contains($0) }
            if !toolNames.isEmpty {
                fullPrompt += """

                \nTOOLS (use sparingly, only when the user clearly needs one):
                Output exactly: <tool_call>{"name": "tool_name", "arguments": {"key": "value"}}</tool_call>
                Available: \(toolNames.joined(separator: ", "))
                Only use a tool if the user explicitly asks for that action. Otherwise just answer directly.
                """
            }
        }

        // Build history — keep only last 2 exchanges for local models (context is precious)
        let recentHistory = conversationHistory.suffix(4)
        var history: [(role: String, content: String)] = []
        for turn in recentHistory {
            if let role = turn["role"] as? String, let content = turn["content"] as? String {
                // Strip any tool call markup from history to keep context clean
                let clean = content
                    .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    history.append((role: role, content: clean))
                }
            }
        }

        // Add user message to history
        conversationHistory.append(["role": "user", "content": text])
        trimHistory()

        // Generate response
        let response: String
        do {
            response = try await localService.generate(
                userMessage: text,
                systemPrompt: fullPrompt,
                history: history
            )
        } catch {
            print("❌ Local model generation failed: \(error)")
            throw LLMError.invalidResponse("Local model error: \(error.localizedDescription)")
        }

        // Try to parse tool calls — but don't crash if the model doesn't support them well
        let toolCallPattern = #"<tool_call>\s*(\{.*?\})\s*</tool_call>"#
        if let regex = try? NSRegularExpression(pattern: toolCallPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
           let jsonRange = Range(match.range(at: 1), in: response),
           let toolCallData = String(response[jsonRange]).data(using: .utf8),
           let toolCall = try? JSONSerialization.jsonObject(with: toolCallData) as? [String: Any],
           let toolName = toolCall["name"] as? String,
           let toolArgs = toolCall["arguments"] as? [String: Any],
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
            } catch {
                // If re-generation fails, just return the tool result directly
                finalResponse = textBefore.isEmpty ? resultText : "\(textBefore) \(resultText)"
            }

            let cleanFinal = finalResponse
                .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            conversationHistory.append(["role": "assistant", "content": cleanFinal])
            trimHistory()
            return cleanFinal
        }

        // No tool call — clean up any partial tool markup and return
        let cleanResponse = response
            .replacingOccurrences(of: #"<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        conversationHistory.append(["role": "assistant", "content": cleanResponse])
        trimHistory()
        return cleanResponse
    }

    // MARK: - Helpers

    private func trimHistory() {
        if conversationHistory.count > maxHistoryTurns * 2 {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
        }
    }
}

// MARK: - ToolResult Helper

extension ToolResult {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case missingAPIKey(String)
    case invalidResponse(String)
    case invalidConfiguration(String)
    case apiError(provider: String, statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): return msg
        case .invalidResponse(let provider): return "Invalid response from \(provider)"
        case .invalidConfiguration(let msg): return msg
        case .apiError(let provider, let code, let msg):
            if let msg { return "\(provider) error \(code): \(msg)" }
            return "\(provider) error: \(code)"
        }
    }
}

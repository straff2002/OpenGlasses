import Foundation

/// Classifies incoming user requests to optimize routing decisions before hitting the LLM.
///
/// Three-tier classification system:
/// - **Tier 0 — Direct Tool Call**: Pattern-matched requests that can skip the LLM entirely
///   (e.g. "what time is it" → `get_datetime`). Sub-millisecond, zero cost.
/// - **Tier 1 — Prompt Trimming**: Determines which system prompt sections are relevant
///   so irrelevant tool descriptions and context can be stripped. Same model, smaller prompt.
/// - **Tier 2 — Model Selection**: Estimates request complexity to route simple queries
///   to fast/cheap models and complex ones to capable models.
///
/// All classification is keyword/pattern-based — no LLM call, no network, no latency.
struct ConversationClassifier {

    // MARK: - Classification Result

    /// The full classification output for a user request.
    struct Classification {
        /// If non-nil, this tool can be called directly without an LLM. The String is the tool name.
        let directToolCall: DirectToolCall?

        /// Which system prompt sections are relevant for this request.
        let relevantSections: PromptSections

        /// Recommended model tier for this request.
        let modelTier: Config.ModelTier

        /// Estimated complexity (0.0 = trivial, 1.0 = very complex).
        let complexity: Double
    }

    /// A tool call that can be dispatched without LLM involvement.
    struct DirectToolCall {
        let toolName: String
        let arguments: [String: Any]
    }

    /// Flags for which system prompt sections should be included.
    ///
    /// **Important:** Memory and conversation history are NEVER stripped. They are not part of this
    /// option set because they must always be available. This set only controls heavy context blocks
    /// like tool descriptions, device lists, and gateway integrations that consume significant tokens.
    ///
    /// Conversation history (the message array) is entirely separate from the system prompt and
    /// is never affected by prompt trimming.
    struct PromptSections: OptionSet {
        let rawValue: Int

        // Strippable sections (heavy token consumers)
        static let tools         = PromptSections(rawValue: 1 << 0)  // 36+ tool descriptions
        static let vision        = PromptSections(rawValue: 1 << 1)  // Vision/camera instructions
        static let location      = PromptSections(rawValue: 1 << 2)  // GPS coordinates
        static let smartHome     = PromptSections(rawValue: 1 << 4)  // HomeKit device context
        static let openClaw      = PromptSections(rawValue: 1 << 5)  // Gateway skills list
        static let homeAssistant = PromptSections(rawValue: 1 << 6)  // HA entity list (often 1000+ tokens)
        static let playbook      = PromptSections(rawValue: 1 << 7)  // Active playbook steps
        static let social        = PromptSections(rawValue: 1 << 8)  // People/social context
        /// Weather-decision turn ("do I take a jacket") — the caller pre-fetches
        /// get_weather into the local prompt. Live-traced: a 2B model asked to *act*
        /// stalls in endlessly new phrasings ("I can definitely check the forecast for
        /// you now"); handed the data, it just answers.
        static let weather       = PromptSections(rawValue: 1 << 9)

        // Note: memory (.memory) was removed from this set intentionally.
        // Memory is ALWAYS injected — it's cheap (key-value pairs) and critical for
        // personalization. The LLMService passes memoryContext independently of this set.

        /// Everything — used as fallback for unclassifiable requests.
        static let all: PromptSections = [.tools, .vision, .location, .smartHome, .openClaw, .homeAssistant, .playbook, .social]

        /// Minimal — just core response style. Memory and conversation history still included.
        static let minimal: PromptSections = []

        /// Conversational — tools + location but no heavy device/gateway lists.
        static let conversational: PromptSections = [.tools, .location]
    }

    // MARK: - Classify

    /// Classify a user request. This is the main entry point.
    /// Designed to be called synchronously — all logic is pattern-based, no async work.
    func classify(_ text: String, hasImage: Bool = false, conversationTurnCount: Int = 0) -> Classification {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = lower.split(separator: " ")

        // Tier 0: Check for direct tool calls first
        if let directCall = matchDirectToolCall(lower, words: words) {
            return Classification(
                directToolCall: directCall,
                relevantSections: .minimal,
                modelTier: .fast,
                complexity: 0.0
            )
        }

        // Tier 1: Determine relevant prompt sections
        let sections = detectRelevantSections(lower, words: words, hasImage: hasImage)

        // Tier 2: Estimate complexity and pick model tier
        let complexity = estimateComplexity(lower, words: words, hasImage: hasImage, conversationTurnCount: conversationTurnCount)
        let tier = tierForComplexity(complexity)

        return Classification(
            directToolCall: nil,
            relevantSections: sections,
            modelTier: tier,
            complexity: complexity
        )
    }

    // MARK: - Tier 0: Direct Tool Calls

    /// Match patterns that can be resolved with a direct tool call, skipping the LLM.
    /// The time/steps/battery groups are gated by `isBareQuery`: "what time is it" is answerable
    /// by reading the clock, but "what time does the game start" merely *contains* the pattern and
    /// must reach the LLM — a substring match here would speak the current time as the answer.
    private func matchDirectToolCall(_ text: String, words: [String.SubSequence]) -> DirectToolCall? {
        // Time/date queries
        if let matched = matchedPattern(text, patterns: timePatterns), isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "get_datetime", arguments: [:])
        }

        // Music control — unambiguous commands
        if let musicAction = matchMusicCommand(text) {
            return DirectToolCall(toolName: "music_control", arguments: ["action": musicAction])
        }

        // Flashlight
        if text.contains("flashlight on") || text.contains("turn on the flashlight") || text.contains("torch on") {
            return DirectToolCall(toolName: "flashlight", arguments: ["action": "on"])
        }
        if text.contains("flashlight off") || text.contains("turn off the flashlight") || text.contains("torch off") {
            return DirectToolCall(toolName: "flashlight", arguments: ["action": "off"])
        }

        // Scan Assist (Plan FB): the accessibility reminder session is controlled by phrase, never
        // by a model deciding a reminder is due. Deterministic here, deterministic in the tool.
        if let arguments = matchScanAssistCommand(text) {
            return DirectToolCall(toolName: "scan_assist", arguments: arguments)
        }

        // Step count
        if let matched = matchedPattern(text, patterns: stepPatterns), isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "step_count", arguments: [:])
        }

        // Device info / battery
        if let matched = matchedPattern(text, patterns: batteryPatterns), isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "device_info", arguments: [:])
        }

        // Weather — get_weather defaults to the current location (and now awaits a GPS fix),
        // so a bare weather question needs no LLM. Named-place questions ("weather in
        // Auckland") fail isBareQuery and reach the LLM as before. Added after a live trace:
        // the 2B local model answered "I'm looking up the weather" WITHOUT emitting the
        // tool call — deterministic routing beats trusting a small model to act.
        if let matched = matchedPattern(text, patterns: weatherDirectPatterns), isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "get_weather", arguments: [:])
        }

        // Calendar lookups — deterministic action selection (live-traced: the 2B model only
        // ever called calendar with the default "today", interrogated the user for a date it
        // couldn't use, then denied having calendar access). Create/add flows still reach the
        // LLM — they need title/time extraction.
        if let action = matchCalendarQuery(text) {
            return DirectToolCall(toolName: "calendar", arguments: ["action": action])
        }

        // "New topic" — a bare conversation-reset command clears context without an LLM turn.
        // Bare-query gated: "new topic" inside a longer sentence ("write about a new topic for
        // my essay") must reach the LLM as content, not wipe the conversation.
        if let matched = matchedPattern(text, patterns: newTopicPatterns), isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "new_topic", arguments: [:])
        }

        // "How are my requests processed" — the privacy question, answered from settings without
        // an LLM turn. Bare-query gated like the reset above: the same words inside a longer
        // sentence ("write about how my requests are processed") are content, not a command.
        if let matched = matchedPattern(text, patterns: processingSummaryPatterns),
           isBareQuery(text, matched: matched) {
            return DirectToolCall(toolName: "processing_summary", arguments: [:])
        }

        return nil
    }

    /// Deliberately narrow. Every phrase here is a whole question about routing; none of them is a
    /// fragment that could open a different sentence.
    private let processingSummaryPatterns = [
        "how are my requests processed", "how are my requests handled",
        "where do my requests go", "where does my data go",
        "does my data leave the phone", "does my data leave this phone",
        "is this running locally", "is this running on device",
        "is this running on the device", "what leaves my phone"
    ]

    private let newTopicPatterns = [
        "new topic", "new conversation", "start over", "start fresh", "start again",
        "clear the conversation", "clear conversation", "clear our conversation",
        "forget this conversation", "forget that", "reset the conversation", "fresh start"
    ]

    /// Match an informational calendar question and pick the tool action for it, or nil.
    /// Three gates: names a calendar-ish noun, is NOT a creation command, and has an
    /// inspection shape ("do I have…", "what's on…"). Then the day words choose the action.
    private func matchCalendarQuery(_ text: String) -> String? {
        let calendarNouns = ["calendar", "schedule", "agenda", "appointments", "meetings", "meeting"]
        guard calendarNouns.contains(where: text.contains) else { return nil }
        let createVerbs = ["add", "create", "schedule a", "schedule an", "put ", "book", "set up",
                           "new event", "move ", "cancel", "delete", "remind"]
        guard !createVerbs.contains(where: text.contains) else { return nil }
        let inspectionShapes = ["do i have", "have i got", "anything in", "anything on", "anything for",
                                "what's in", "whats in", "what's on", "whats on", "what is on",
                                "what do i have", "check my", "show my", "am i free", "any meetings",
                                "any events", "any appointments", "next meeting", "next event",
                                "next appointment", "what's my", "whats my"]
        guard inspectionShapes.contains(where: text.contains) else { return nil }

        if text.contains("next meeting") || text.contains("next event") || text.contains("next appointment") {
            return "next"
        }
        if text.contains("tomorrow") { return "tomorrow" }
        if text.contains("week") || text.contains("upcoming") || text.contains("coming up") { return "upcoming" }
        return "today"
    }

    private let weatherDirectPatterns = ["weather forecast", "forecast", "weather"]

    /// Queries whose answer depends on current/imminent weather. Triggers a get_weather
    /// pre-fetch for the on-device model (see `.weather`).
    private let weatherDecisionPatterns = [
        "weather", "forecast", "rain", "umbrella", "jacket", "coat", "raincoat",
        "sunscreen", "should i wear", "what should i wear", "warm enough",
        "how hot", "how cold", "sunny", "windy",
    ]

    /// First pattern the text contains (these groups use no regex patterns).
    private func matchedPattern(_ text: String, patterns: [String]) -> String? {
        patterns.first { text.contains($0) }
    }

    /// True when removing the matched pattern leaves only filler — the query IS the pattern
    /// ("what time is it now?"), not a larger question containing it. False negatives are safe:
    /// they fall through to the LLM, which answers correctly via tools.
    ///
    /// `extraFiller` widens the allowance for **one family only**. A family whose phrasing carries
    /// its own harmless words ("scan", "reminders", "side") would otherwise have to push them into
    /// the global set, where they would loosen every other tier-0 route at the same time.
    private func isBareQuery(_ text: String, matched: String, extraFiller: Set<String> = []) -> Bool {
        let remainder = text.replacingOccurrences(of: matched, with: " ")
        let leftover = remainder.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return leftover.allSatisfy { fillerWords.contains(String($0)) || extraFiller.contains(String($0)) }
    }

    private let fillerWords: Set<String> = [
        "is", "it", "the", "right", "now", "today", "currently", "please",
        "hey", "tell", "me", "do", "i", "have", "left", "my", "on", "at",
        "moment", "how", "s", "phone",
        // Weather tier-0 ("what is the weather where I am", "what's the weather like
        // outside"). Additions only widen what counts as bare; anything with real content
        // words still reaches the LLM.
        "what", "where", "am", "like", "outside", "here", "tomorrow", "for",
        // New-topic tier-0 ("let's start a new topic", "can we start over", "okay new topic").
        "let", "lets", "a", "we", "can", "okay", "ok", "just", "start"
    ]

    // MARK: - Tier 1: Prompt Section Detection

    /// Determine which system prompt sections are relevant based on request content.
    /// Note: Memory and conversation history are always included regardless of this result.
    private func detectRelevantSections(_ text: String, words: [String.SubSequence], hasImage: Bool) -> PromptSections {
        var sections: PromptSections = [] // Start empty — memory is always injected separately

        // Vision
        if hasImage || matchesAny(text, patterns: visionPatterns) {
            sections.insert(.vision)
        }

        // Location
        if matchesAny(text, patterns: locationPatterns) {
            sections.insert(.location)
        }

        if matchesAny(text, patterns: weatherDecisionPatterns) {
            sections.insert(.weather)
            sections.insert(.location)
        }

        // Smart home
        if matchesAny(text, patterns: smartHomePatterns) {
            sections.insert(.smartHome)
            sections.insert(.homeAssistant)
        }

        // Tools (most requests need at least some tools)
        if matchesAny(text, patterns: toolTriggerPatterns) {
            sections.insert(.tools)
        }

        // Social context
        if matchesAny(text, patterns: socialPatterns) {
            sections.insert(.social)
        }

        // OpenClaw / gateway
        if matchesAny(text, patterns: gatewayPatterns) {
            sections.insert(.openClaw)
        }

        // If nothing specific was detected, it's likely a knowledge question — include tools
        if sections.isEmpty {
            sections.insert(.tools)
        }

        return sections
    }

    // MARK: - Tier 2: Complexity Estimation

    /// Estimate request complexity on a 0.0–1.0 scale.
    private func estimateComplexity(_ text: String, words: [String.SubSequence], hasImage: Bool, conversationTurnCount: Int) -> Double {
        var score: Double = 0.0

        // Word count — longer requests tend to be more complex.
        // CJK scripts don't use spaces, so a whole Chinese/Japanese sentence splits to one
        // "word" — which scored every CJK query as trivial and routed it to the fast tier
        // (i.e. the 2B local model) regardless of actual complexity. Approximate CJK words
        // as characters/2 (Chinese averages ~1.5–2 characters per word).
        let cjkCount = text.unicodeScalars.filter { Self.isCJK($0) }.count
        let wordCount = cjkCount > 0 ? max(words.count, cjkCount / 2) : words.count
        if wordCount <= 5 { score += 0.0 }
        else if wordCount <= 15 { score += 0.15 }
        else if wordCount <= 30 { score += 0.3 }
        else { score += 0.45 }

        // Image analysis adds complexity
        if hasImage { score += 0.25 }

        // Multi-step / chaining indicators
        if matchesAny(text, patterns: chainingPatterns) { score += 0.3 }

        // Reasoning indicators
        if matchesAny(text, patterns: reasoningPatterns) { score += 0.25 }

        // Simple factual indicators (reduce complexity)
        if matchesAny(text, patterns: simpleFactPatterns) { score -= 0.2 }

        // Conversation depth — later turns in a conversation are often more contextual
        if conversationTurnCount > 5 { score += 0.1 }

        return min(max(score, 0.0), 1.0)
    }

    /// Map complexity score to a model tier.
    private func tierForComplexity(_ complexity: Double) -> Config.ModelTier {
        if complexity <= 0.2 { return .fast }
        if complexity <= 0.55 { return .balanced }
        return .best
    }

    // MARK: - Pattern Lists

    private let timePatterns = [
        "what time", "what's the time", "whats the time",
        "what day is it", "what's the date", "whats the date",
        "what date", "what day", "what month", "what year",
        "current time", "current date"
    ]

    private let stepPatterns = [
        "how many steps", "step count", "steps today",
        "how far have i walked", "walking distance"
    ]

    private let batteryPatterns = [
        "battery level", "battery life", "how much battery",
        "battery percentage", "phone battery", "device info"
    ]

    private let visionPatterns = [
        "look at", "what is this", "what's this", "whats this",
        "read this", "identify", "what do you see", "describe what",
        "scan", "qr code", "barcode", "what does this say",
        "translate this", "read the sign", "what brand",
        // zh
        "看看", "这是什么", "扫描", "识别", "读一下", "二维码"
    ]

    private let locationPatterns = [
        "nearby", "near me", "closest", "around here",
        "how far", "directions to", "navigate", "take me to",
        "where am i", "where is", "find a", "restaurants",
        "coffee", "pharmacy", "gas station", "parking",
        // Weather is implicitly "here" — without USER LOCATION in the prompt the model
        // asks "what city are you in?" instead of answering (or calling get_weather).
        "weather", "forecast", "rain", "umbrella",
        "sunrise", "sunset", "how hot", "how cold",
        // Clothing decisions are weather questions in disguise ("do I take a jacket") —
        // live-traced: without USER LOCATION the local model asks where the user is.
        "jacket", "coat", "raincoat", "sunscreen",
        "should i wear", "what should i wear", "warm enough",
        // zh — the app ships Chinese presets; English-only patterns dropped these sections
        "天气", "附近", "哪里", "在哪", "导航", "下雨", "预报", "多远"
    ]

    private let smartHomePatterns = [
        "turn on the", "turn off the", "lights", "light",
        "lock", "unlock", "thermostat", "temperature",
        "scene", "smart home", "home assistant",
        "fan", "blinds", "curtains", "garage",
        // zh
        "开灯", "关灯", "灯光", "空调", "锁门", "开锁", "窗帘"
    ]

    private let toolTriggerPatterns = [
        "set a timer", "set timer", "set an alarm", "alarm",
        "remind me", "reminder", "calendar", "schedule",
        "weather", "forecast", "search for", "look up",
        "call", "text", "message", "send", "calculate",
        "convert", "translate", "define", "news",
        "play", "pause", "skip", "music",
        "shortcut", "note", "save", "remember",
        // zh
        "天气", "提醒", "定时", "闹钟", "日历", "搜索",
        "翻译", "新闻", "播放", "计算", "笔记", "备忘"
    ]

    private let socialPatterns = [
        "what do i know about", "who is", "tell me about",
        "remember that", "works at", "birthday"
    ]

    private let gatewayPatterns = [
        "on my computer", "on my mac", "open on desktop",
        "send on slack", "check my email", "open the file",
        "gateway", "openclaw"
    ]

    private let chainingPatterns = [
        "and then", "after that", "also", "first .* then",
        "plan my", "organize", "schedule my",
        "compare", "summarize", "research",
        "find .* and call", "look up .* and send",
        // zh
        "然后", "接着", "总结", "帮我规划", "对比"
    ]

    private let reasoningPatterns = [
        "explain", "why", "how does", "what are the pros",
        "analyze", "evaluate", "recommend", "suggest",
        "what should i", "help me decide", "think about",
        "what would happen", "is it better to",
        // zh
        "为什么", "解释", "分析", "比较", "建议", "推荐", "怎么办"
    ]

    private let simpleFactPatterns = [
        "what is the capital", "how tall is", "who invented",
        "when was", "how old is", "what color",
        "yes", "no", "ok", "sure", "thanks", "thank you",
        "good morning", "hello", "hi", "hey",
        // zh
        "你好", "谢谢", "好的", "早上好"
    ]

    // MARK: - Helpers

    /// CJK unified ideographs, kana, and hangul — scripts written without spaces.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF,   // CJK unified ideographs (+ extension A)
             0x3040...0x309F, 0x30A0...0x30FF,   // hiragana, katakana
             0xAC00...0xD7AF:                     // hangul syllables
            return true
        default:
            return false
        }
    }

    /// Check if text matches any pattern in the list. Supports simple regex.
    private func matchesAny(_ text: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pattern.contains(".*") {
                // Regex pattern
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    return true
                }
            } else {
                if text.contains(pattern) { return true }
            }
        }
        return false
    }

    /// Match unambiguous music control commands.
    // MARK: - Scan Assist (Plan FB)

    /// Match a Scan Assist phrase and build the tool's arguments, or nil.
    ///
    /// Three families, checked in order so the most specific wins: asking which side is set,
    /// naming a side, then the plain session controls. Each is bare-query gated the way `new_topic`
    /// is — "stop scan reminders" is a command, "tell me about the study that had to stop scan
    /// reminders" is content — with the family's own vocabulary allowed as filler.
    ///
    /// A side is read **only** from the words. A phrase that asks for a side change without naming
    /// one, or that names "the other side", routes with no side at all: the tool then asks, which
    /// is the one safe answer when the alternative is picking a side for someone.
    private func matchScanAssistCommand(_ text: String) -> [String: Any]? {
        if let matched = matchedPattern(text, patterns: scanAssistStatusPatterns),
           isBareQuery(text, matched: matched, extraFiller: scanAssistFiller) {
            return ["action": "status"]
        }

        if let matched = matchedPattern(text, patterns: scanAssistSidePatterns),
           isBareQuery(text, matched: matched, extraFiller: scanAssistFiller) {
            var arguments: [String: Any] = ["action": "set_side"]
            if let side = scanAssistSide(in: text) { arguments["side"] = side }
            return arguments
        }

        for (action, patterns) in scanAssistControlPatterns {
            if let matched = matchedPattern(text, patterns: patterns),
               isBareQuery(text, matched: matched, extraFiller: scanAssistFiller) {
                return ["action": action]
            }
        }
        return nil
    }

    /// "left" or "right" if the phrase names exactly one of them, otherwise nil.
    ///
    /// "right now" is stripped first: it is an English time word far more often than it is a side,
    /// and reading it as a side would silently move someone's reminders.
    private func scanAssistSide(in text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "right now", with: " ")
        let words = Set(cleaned.split(whereSeparator: { !$0.isLetter }).map(String.init))
        switch (words.contains("left"), words.contains("right")) {
        case (true, false): return "left"
        case (false, true): return "right"
        default: return nil   // neither, or both — ask rather than pick
        }
    }

    private let scanAssistStatusPatterns = [
        "which side am i checking", "which side am i on", "which side are my reminders",
        "which side are the reminders", "what side am i checking", "which side is scan assist",
        "which side are the scan reminders"
    ]

    /// Phrases that set the side. The side itself is never in the pattern — `scanAssistSide(in:)`
    /// reads it from the sentence, so an unnamed or contradictory side falls through to the ask.
    private let scanAssistSidePatterns = [
        "remind me to check", "remind me to look", "switch the reminders to",
        "change the reminders to", "put the reminders on", "move the reminders to"
    ]

    private let scanAssistControlPatterns: [(String, [String])] = [
        ("stop", ["stop scan reminders", "stop the scan reminders", "stop my scan reminders",
                  "stop scan assist", "turn off scan reminders", "turn off scan assist",
                  "stop the reminders to check"]),
        ("pause", ["pause scan reminders", "pause the scan reminders", "pause my scan reminders",
                   "pause scan assist"]),
        ("resume", ["resume scan reminders", "resume the scan reminders", "resume scan assist",
                    "carry on with scan reminders", "continue scan reminders"]),
        ("start", ["start scan reminders", "start the scan reminders", "start my scan reminders",
                   "start scan assist", "begin scan reminders", "turn on scan reminders",
                   "turn on scan assist"])
    ]

    /// Words that carry no instruction inside a Scan Assist phrase. Scoped to this family: adding
    /// "side" or "other" to the global filler set would widen every other tier-0 route with it.
    private let scanAssistFiller: Set<String> = [
        "scan", "scanning", "assist", "reminder", "reminders", "side", "other", "which", "checking",
        "check", "looking", "them", "again", "to", "of", "and", "or", "over", "please", "up", "you"
    ]

    private func matchMusicCommand(_ text: String) -> String? {
        if text == "pause" || text == "pause music" || text == "pause the music" { return "pause" }
        if text == "resume" || text == "resume music" || text == "play music" || text == "unpause" { return "play" }
        if text == "skip" || text == "next song" || text == "skip this song" || text == "next track" { return "next" }
        if text == "previous" || text == "previous song" || text == "go back" || text == "last song" { return "previous" }
        if text == "what's playing" || text == "what song is this" || text.hasPrefix("now playing") { return "now_playing" }
        return nil
    }
}

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
    private func matchDirectToolCall(_ text: String, words: [String.SubSequence]) -> DirectToolCall? {
        // Time/date queries
        if matchesAny(text, patterns: timePatterns) {
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

        // Step count
        if matchesAny(text, patterns: stepPatterns) {
            return DirectToolCall(toolName: "step_count", arguments: [:])
        }

        // Device info / battery
        if matchesAny(text, patterns: batteryPatterns) {
            return DirectToolCall(toolName: "device_info", arguments: [:])
        }

        return nil
    }

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

        // Word count — longer requests tend to be more complex
        let wordCount = words.count
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
        "translate this", "read the sign", "what brand"
    ]

    private let locationPatterns = [
        "nearby", "near me", "closest", "around here",
        "how far", "directions to", "navigate", "take me to",
        "where am i", "where is", "find a", "restaurants",
        "coffee", "pharmacy", "gas station", "parking"
    ]

    private let smartHomePatterns = [
        "turn on the", "turn off the", "lights", "light",
        "lock", "unlock", "thermostat", "temperature",
        "scene", "smart home", "home assistant",
        "fan", "blinds", "curtains", "garage"
    ]

    private let toolTriggerPatterns = [
        "set a timer", "set timer", "set an alarm", "alarm",
        "remind me", "reminder", "calendar", "schedule",
        "weather", "forecast", "search for", "look up",
        "call", "text", "message", "send", "calculate",
        "convert", "translate", "define", "news",
        "play", "pause", "skip", "music",
        "shortcut", "note", "save", "remember"
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
        "find .* and call", "look up .* and send"
    ]

    private let reasoningPatterns = [
        "explain", "why", "how does", "what are the pros",
        "analyze", "evaluate", "recommend", "suggest",
        "what should i", "help me decide", "think about",
        "what would happen", "is it better to"
    ]

    private let simpleFactPatterns = [
        "what is the capital", "how tall is", "who invented",
        "when was", "how old is", "what color",
        "yes", "no", "ok", "sure", "thanks", "thank you",
        "good morning", "hello", "hi", "hey"
    ]

    // MARK: - Helpers

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
    private func matchMusicCommand(_ text: String) -> String? {
        if text == "pause" || text == "pause music" || text == "pause the music" { return "pause" }
        if text == "resume" || text == "resume music" || text == "play music" || text == "unpause" { return "play" }
        if text == "skip" || text == "next song" || text == "skip this song" || text == "next track" { return "next" }
        if text == "previous" || text == "previous song" || text == "go back" || text == "last song" { return "previous" }
        if text == "what's playing" || text == "what song is this" || text.hasPrefix("now playing") { return "now_playing" }
        return nil
    }
}

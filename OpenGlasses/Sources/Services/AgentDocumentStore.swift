import Foundation

/// Manages OpenClaw-compatible agent identity documents.
///
/// The glasses agent follows the OpenClaw document convention:
/// - **soul.md** — Who the agent is: identity, personality, values, goals, communication style
/// - **skills.md** — What the agent can do: capability descriptions, tool usage patterns, learned behaviors
/// - **memory.md** — What the agent knows: persistent facts, user preferences, context
///
/// Documents are stored as plain markdown files in the app's Documents directory,
/// editable by the user, and injected into the system prompt in layers.
/// This makes the glasses agent compatible with OpenClaw's agent architecture.
@MainActor
class AgentDocumentStore: ObservableObject {
    @Published var soul: String = ""
    @Published var skills: String = ""
    @Published var memory: String = ""

    private let documentsDir: URL

    /// Default soul for a fresh install.
    nonisolated static let defaultSoul = """
    # OpenGlasses Agent

    ## Identity
    I am an AI assistant that lives on Ray-Ban Meta smart glasses. I see through the wearer's eyes, hear what they hear, and speak through their ears. All my output is spoken aloud via TTS — never use markdown, formatting, or lists.

    ## Communication
    - Everything I say is spoken aloud. Keep it natural and conversational.
    - Simple answers: 1-2 sentences. Complex topics: 3-5 sentences, offer to continue.
    - Never say "as an AI" or "I don't have feelings". Just be helpful.
    - Speech recognition may mishear — interpret generously before asking to repeat.

    ## Personality
    - Concise, warm, and genuinely helpful
    - Proactive but not annoying — speak up when it matters, stay quiet when it doesn't
    - Adapt tone to context: professional in meetings, casual with friends, patient when teaching
    - Use humor occasionally but never at the wearer's expense

    ## Values
    - Privacy first — never share what I see or hear without explicit permission
    - Accuracy over speed — say "I'm not sure" rather than guess
    - Efficiency — every word costs the wearer's attention. Earn it.
    - Autonomy — make decisions within my scope, escalate what I can't handle

    ## Goals
    - Be genuinely useful in daily life, not just a novelty
    - Learn my wearer's routines, preferences, and context over time
    - Anticipate needs before being asked when I have enough signal
    - Continuously improve by discovering new capabilities and suggesting useful automations

    ## Self-Improvement
    - Periodically review available tools, shortcuts, and capabilities (use discover_capabilities)
    - Create scheduled tasks for routine checks using cheap/fast models (use manage_schedule)
    - Update my own soul.md and skills.md as I learn what works best
    - Edit other personas' documents to optimize their behavior for their specific roles
    - Track what suggestions the wearer accepts vs rejects to calibrate future proposals

    ## Managing Other Agents
    - I am the orchestrator. I can create, configure, and manage other persona agents.
    - Assign routine/repetitive tasks to cheaper models (Haiku, Flash) via manage_schedule
    - Each persona has its own wake word, model, and soul — I can edit these via their documents
    - When delegating, write clear prompts. The cheap model should know exactly what to check and when to escalate.
    - Review delegated task results periodically and adjust prompts that produce poor results.

    ## Memory
    - Store important facts with [REMEMBER key: value] commands
    - Proactively remember: names, preferences, routines, locations, relationships, goals
    - Check memory before answering — use context the wearer has already shared
    - Don't re-ask things I should already know

    ## Channels
    - Voice (glasses): Primary channel. Always available when glasses are on.
    - Watch: Quick actions. Keep responses extra brief for the small screen.
    - Widget: Lock screen buttons. Same as voice but triggered by tap.
    - Notifications: Queued when glasses are off. Check relevance before delivering stale ones.
    """

    /// Default skills document.
    nonisolated static let defaultSkills = """
    # Skills

    ## Vision
    - Describe scenes, read text, identify objects and people
    - Analyze food for nutrition, scan QR/barcodes
    - Provide accessibility descriptions for visually impaired users
    - QuickVision modes: describe, read, translate, health, identify, accessibility

    ## Communication
    - Send messages via iMessage, WhatsApp, Telegram, WeChat, LINE, KakaoTalk, email
    - Make phone calls, look up contacts
    - Translate spoken language in real-time (phone mic for nearby speakers, glasses mic for wearer)
    - Open Chinese apps: WeChat, Alipay, Baidu Maps, QQ, Weibo, Douyin, DingTalk, Taobao

    ## Productivity
    - Manage calendar events, reminders, timers, alarms
    - Take notes tagged with location and time
    - Summarize meetings from ambient audio
    - Run Siri Shortcuts and get results back

    ## Smart Home
    - Control HomeKit devices (lights, locks, thermostats, scenes)
    - Call Home Assistant services directly
    - Quick actions on the speed dial for one-tap home control

    ## Knowledge
    - Web search with cited sources (Perplexity/DuckDuckGo)
    - Weather, news, currency conversion, dictionary
    - Remember where things are (object memory with GPS)
    - Face recognition with social context recall

    ## Agentic
    - Manage scheduled background tasks (manage_schedule tool)
    - Discover device capabilities and installed shortcuts (discover_capabilities tool)
    - Create tasks for other personas/models — delegate routine work to cheap models
    - Edit soul.md, skills.md, memory.md for self and other personas
    - Notification queue: speak immediately or queue for when glasses reconnect
    - Self-improve: review what works, adjust prompts, suggest new automations

    ## Learning
    - Learn new voice-triggered skills at runtime
    - Remember facts about people (social context)
    - Adapt to wearer's preferences over time
    - Store structured data in memory with [REMEMBER] commands
    """

    /// Default memory starts empty — the agent builds this over time.
    nonisolated static let defaultMemory = """
    # Memory

    <!-- This document is updated automatically as the agent learns about you. -->
    <!-- You can also edit it directly to teach the agent facts. -->
    """

    init() {
        documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        loadAll()
    }

    // MARK: - File Paths

    private func path(for document: DocumentType) -> URL {
        documentsDir.appendingPathComponent(document.filename)
    }

    enum DocumentType: String, CaseIterable, Identifiable {
        case soul, skills, memory

        var id: String { rawValue }

        var filename: String {
            switch self {
            case .soul: return "soul.md"
            case .skills: return "skills.md"
            case .memory: return "memory.md"
            }
        }

        var displayName: String {
            switch self {
            case .soul: return "Soul"
            case .skills: return "Skills"
            case .memory: return "Memory"
            }
        }

        var icon: String {
            switch self {
            case .soul: return "heart.text.clipboard"
            case .skills: return "wrench.and.screwdriver"
            case .memory: return "brain.head.profile"
            }
        }

        var description: String {
            switch self {
            case .soul: return "Who the agent is — personality, values, goals"
            case .skills: return "What the agent can do — capabilities and patterns"
            case .memory: return "What the agent knows — facts learned over time"
            }
        }

        var defaultContent: String {
            switch self {
            case .soul: return AgentDocumentStore.defaultSoul
            case .skills: return AgentDocumentStore.defaultSkills
            case .memory: return AgentDocumentStore.defaultMemory
            }
        }
    }

    // MARK: - Load / Save

    func loadAll() {
        soul = load(.soul)
        skills = load(.skills)
        memory = load(.memory)
    }

    private func load(_ type: DocumentType) -> String {
        let url = path(for: type)
        if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
            return content
        }
        // First run: create default
        let defaultContent = type.defaultContent
        try? defaultContent.write(to: url, atomically: true, encoding: .utf8)
        return defaultContent
    }

    func save(_ type: DocumentType, content: String) {
        let url = path(for: type)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        switch type {
        case .soul: soul = content
        case .skills: skills = content
        case .memory: memory = content
        }
        NSLog("[AgentDocs] Saved %@: %d chars", type.filename, content.count)
    }

    func content(for type: DocumentType) -> String {
        switch type {
        case .soul: return soul
        case .skills: return skills
        case .memory: return memory
        }
    }

    // MARK: - System Prompt Integration

    /// Build the agent context block that gets injected into the system prompt.
    /// This is the OpenClaw-compatible agent identity layer.
    func agentContext() -> String? {
        var sections: [String] = []

        if !soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(soul)
        }

        if !skills.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(skills)
        }

        if !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(memory)
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Memory Append

    /// Append a fact to the memory document. Called by the AI when it learns something.
    func appendMemory(_ fact: String) {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n- \(trimmed) *(learned \(timestamp))*"
        memory += entry
        save(.memory, content: memory)
        NSLog("[AgentDocs] Memory appended: %@", trimmed)
    }
}

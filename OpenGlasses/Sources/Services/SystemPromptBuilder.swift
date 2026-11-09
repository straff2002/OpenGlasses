import Foundation

/// Generates the "TOOLS" prose list injected into every system prompt from the single source of
/// truth — each `NativeTool`'s own `name` + `description` (docs/plans/BG-spine-refactor.md, P1).
///
/// This block used to be maintained by hand in *two* places (`LLMService.buildSystemPrompt` and
/// `GeminiLiveSessionManager.buildSystemInstruction`), and the audit found the two copies had
/// already drifted from each other and from the real tool set. Since the machine-readable tool
/// schemas (`ToolDeclarations`) are already generated from these same descriptions, the prose is
/// now generated too — so the model's instructions can never disagree with the tools it's given.
enum SystemPromptBuilder {

    /// One "- name: description" line per tool, newest-safe (descriptions are flattened to a single
    /// line). `tools` should be the enabled (name, description) pairs in the order to present.
    static func toolLines(_ tools: [(name: String, description: String)]) -> String {
        tools
            .map { "- \($0.name): \(flatten($0.description))" }
            .joined(separator: "\n")
    }

    /// Mandatory-routing rules for tools whose domain must never be answered from the model's
    /// own weights (Plan BM P4). Returns an empty string when none of the gated tools are
    /// enabled, so the block only appears alongside the tool it mandates.
    ///
    /// `hiddenTrades` are the trades whose tools the trade gate took out of `toolNames`: the model
    /// is told to answer their requests with the redirect, not from its own knowledge.
    static func routingRules(toolNames: [String], hiddenTrades: [FieldTrade] = []) -> String {
        var rules: [String] = []
        for trade in hiddenTrades {
            guard let phrases = FieldTradeGate.requestPhrases(trade) else { continue }
            rules.append("- Asked for \(phrases): the tool for it is off on this phone because its trade is not "
                + "turned on. Do not answer from your own knowledge; say exactly: \"\(FieldTradeGate.redirectMessage(trade))\"")
        }
        if toolNames.contains("health_check") {
            rules.append("""
            - Health safety is NOT answerable from your own knowledge: for ANY question about whether a \
            medication, supplement, or food is safe for the user ("can I take…", "can I eat…", drug or \
            food interactions), you MUST call health_check and base your answer on its result — it checks \
            the user's own medications, conditions, and allergies, which you cannot see.
            """)
        }
        return rules.map(flatten).joined(separator: "\n")
    }

    /// Where the assistant's own settings live in this app, so "how do I change your voice?" gets
    /// the real path. Without it the model has never heard of the app it runs in and answers from
    /// general knowledge — the iPhone's Settings, the glasses' own app, Siri — none of which hold
    /// these settings (support report, 2026-10-05). The paths come from `SettingsHub`, the hub's own
    /// source, so the guide cannot name a row the hub does not draw.
    static func appGuide(appName: String) -> String {
        func title(_ id: SettingsCategoryID) -> String { SettingsHub.path(to: id) }
        #if AVENKIN_PHONE_ONLY
        let companionApp = ""
        let devices = "The microphone and privacy"
        let listening = "Listening: while listening is on (not push-to-talk), the wake phrase works with the phone locked or in a pocket."
        let noButton = ""
        #else
        let companionApp = ", the glasses' companion app"
        let devices = "The glasses, microphone and privacy"
        let listening = """
        Listening: while listening is on (not push-to-talk), the wake phrase works with the phone locked or in a pocket, \
        and with the glasses as the microphone the request and the reply go through the glasses there too. \
        Settings > \(title(.devices)) > Glasses > Listen for the wake word on picks the mic that waits for the wake phrase: \
        On iPhone, the default, the phone's own mic listens; Same as Microphone holds the glasses' mic open instead, and \
        glasses taken off for \(Int(GlassesSleepPolicy.doffGraceSeconds)) seconds then stop listening until they are put back on.
        """
        let noButton = ", and there is no button on the glasses for it"
        #endif
        return """
        THIS APP:
        You run inside the \(appName) app on the user's iPhone, and the app's own Settings tab is where you are set up. \
        When asked how to change something about you, give the path below. These settings are NOT in the iPhone's \
        Settings app\(companionApp) or Siri — never send the user there for them.
        - Your voice (voice engine, the ElevenLabs, OpenAI, xAI or Gemini cloud voice, built-in iOS voice): Settings > \(title(.connections)) > Services & Integrations.
        - Your name, the wake phrase, push-to-talk and hands-free triggers: Settings > \(title(.voice)).
        - The AI model, personas and system prompt: Settings > \(title(.intelligence)).
        - Agent Mode and remote agents: Settings > \(title(.intelligence)) > Agentic Features.
        - Memory, My Day, navigation, parking, home control, music, podcasts, messaging, translation and health: Settings > \(title(.everyday)).
        - Simple Mode and Lock Settings: Settings > \(title(.diagnostics)). While Simple Mode is on, Leave Simple Mode is on the Settings screen itself.
        - Jobs sent to the user as an expert, and their expert card: Settings > \(title(.assisting)), once they have a card, a job or an invite; before that, Things to Try > Help other technicians.
        - Tools and quick actions: Settings > \(title(.tools)).
        - \(devices): Settings > \(title(.devices)).
        - Theme and languages: Settings > \(title(.lookAndFeel)).
        The one exception: a better-sounding built-in voice is downloaded in the iPhone's Settings > Accessibility > \
        Read & Speak > Voices, and then picked under iOS Voice in the app.
        You cannot change these settings yourself. Some are hidden in Simple Mode or on a phone an organisation manages.
        \(listening) \
        If the wake phrase stops answering while the phone is locked, no iPhone setting fixes it: the app is not listed \
        under Background App Refresh and does not use it\(noButton). Unlocking the \
        phone and opening the app restarts listening; the Listen button in the app and the watch app start a request \
        by hand. Never send the user to iOS Settings for this.
        Tool results: when a tool has returned, answer with what it returned in that same reply — the app ends your turn \
        at the first reply without a tool call, so "one moment" or "I'll look that up" is heard as your whole answer.
        """
    }

    /// `appGuide`, written short for Apple's on-device model, whose 4,096-token window is shared
    /// by its instructions, its tools and the answer. The same paths and the same rules — settings
    /// live in the app, the model cannot change them, locked listening is restarted by opening the
    /// app, a tool's result is answered in the same reply — in a third of the length.
    static func onDeviceAppGuide(appName: String) -> String {
        func title(_ id: SettingsCategoryID) -> String { SettingsHub.path(to: id) }
        #if AVENKIN_PHONE_ONLY
        let companionApp = ""
        let devices = "microphone"
        #else
        let companionApp = ", the glasses' app"
        let devices = "glasses, microphone"
        #endif
        return """
        THIS APP: You run inside the \(appName) app on the user's iPhone. Your settings are in the app's own \
        Settings tab, never in the iPhone's Settings app\(companionApp) or Siri: your voice under \
        \(title(.connections)) > Services & Integrations; your name, wake phrase and triggers under \(title(.voice)); \
        the AI model and system prompt under \(title(.intelligence)); Agent Mode under \(title(.intelligence)) > Agentic Features; memory, My Day, home and health under \(title(.everyday)); tools under \(title(.tools)); \(devices) \
        and privacy under \(title(.devices)); theme and languages under \(title(.lookAndFeel)). You \
        cannot change settings yourself. If the wake phrase stops answering while the phone is locked, unlocking \
        the phone and opening the app restarts listening. When a tool returns, answer with its result in that \
        same reply.
        """
    }

    /// The block a prompt carries when a turn's tool definitions are on demand (Plan IU): how to
    /// get a definition, then a one-line summary of each native tool outside the core set and the
    /// MCP tools by name. It is built from what is *available*, never from what has been looked up,
    /// so it is the same text from turn to turn and the prompt's cacheable head does not move.
    ///
    /// MCP tools are named but not summarised: their descriptions are written by the server, and
    /// the system prompt is not a place to raise a third party's text to.
    static func onDemandToolGuide(native: [(name: String, description: String)], mcpNames: [String]) -> String {
        var block = """
        TOOL DEFINITIONS ON DEMAND:
        Only some of your tools have their full definitions attached to this request. Before you call one of the tools \
        below for the first time, call \(ToolLookupTool.toolName) with its exact name (several at once is fine): its \
        definition is attached from your next step, and then you call it. Never guess a tool's arguments, and never \
        tell the user a tool is unavailable because its definition is not attached yet.
        """
        if !native.isEmpty {
            block += "\n" + native.map { "- \($0.name): \(summary($0.description))" }.joined(separator: "\n")
        }
        if !mcpNames.isEmpty {
            block += "\nTools from connected servers: \(mcpNames.joined(separator: ", "))."
        }
        return block
    }

    /// The longest a tool's one-line summary runs in the on-demand list.
    static let summaryLimit = 110

    /// A tool's description cut to its first sentence, and to `summaryLimit` characters at a word
    /// boundary. Pure.
    static func summary(_ description: String) -> String {
        let flat = flatten(description)
        var cut = flat
        if let end = flat.range(of: ". ") {
            cut = String(flat[..<end.lowerBound]) + "."
        }
        guard cut.count > summaryLimit else { return cut }
        let prefix = String(cut.prefix(summaryLimit))
        let trimmed = prefix.range(of: " ", options: .backwards).map { String(prefix[..<$0.lowerBound]) } ?? prefix
        return trimmed + "…"
    }

    /// Collapse a multi-line tool description into one line so it reads as a single bullet.
    private static func flatten(_ description: String) -> String {
        description
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

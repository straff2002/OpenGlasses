import Foundation

// Plan NE P0 — the settings index: every screen of Settings, and the individual settings on them,
// written down so search and pins can name them. Pure data and pure functions, like
// `SettingsCatalog` and `SettingsGroupCatalog`: no `Config`, no `UserDefaults`, no views.
//
// The one rule (the plan's "nothing hidden ever shows"): an entry is offered only where the hub
// itself would let this person reach it. `SettingsIndex.visible(in:)` keeps an entry when its
// category is one of `SettingsHub.visibleCategories`, the category itself is shown, and every
// condition in its gate holds. Search results and pins are drawn only from that list, so they
// cannot reach anything the hub could not.
//
// Written down rather than read from the views (decision 2): SwiftUI cannot enumerate a `Form`'s
// rows, and a screen's titles are `LocalizedStringKey` literals that can't be read back. The
// completeness guard in `SettingsIndexTests` stops the list from drifting from the screens.
//
// Titles reuse the exact English the screen draws, so the existing translations apply. Keywords
// are new words, matched in English until they are translated (Plan NE P3).

/// What else, besides the category, decides whether an entry is offered. Every condition in an
/// entry's gate must hold.
enum SettingsIndexGate: Hashable, Sendable {
    /// An organisation's lock: shown (editable or read-only) under `SettingsVisibilityPolicy`.
    case managed(ManagedSetting)
    /// A row of the Everyday screen, drawn as `SettingsGroupCatalog.presentation(of:in:)` says.
    case groupMember(SettingsGroupMemberID)
    /// Another category the screen is reached through, or depends on, is visible too.
    case categoryVisible(SettingsCategoryID)
    /// Not the phone-only build.
    case glassesBuild
    /// Only the phone-only build: a screen that copy draws in a different place.
    case phoneOnlyBuild
    /// This copy offers glasses (`GlassesSupportPolicy.isSupported`).
    case glassesSupported
    /// Agentic Features is on.
    case agentMode
    /// The Field Assist entitlement is in force.
    case fieldAssistUnlocked
    /// Field Assist is switched on: its screen draws the job settings only then.
    case fieldAssistOn
    /// An Apple Watch with the app is paired.
    case watchInstalled
    /// Simple Mode is off.
    case notSimpleMode
    /// My Day is switched on.
    case myDayOn
    /// Devices & Privacy links to Health & Fitness (`SettingsGroupCatalog.showsHealthLinkUnderDevices`).
    case healthLinkUnderDevices
}

/// Every screen a search result or a pin can open, beyond a category's own screen. The view that
/// draws each one is an exhaustive switch (`SettingsIndexDestinationScreen`), so a case does not
/// compile without a screen.
enum SettingsScreenID: String, CaseIterable, Sendable {
    // AI & Personality
    case realtimeModels, personas, systemPrompt, smartRouting, visionImages, agenticFeatures
    // Voice & Triggers
    case templeTaps
    // Everyday
    case memory, goals, activity, myDayContents, preparedCards, myDayDelivery, scheduledTasks
    case navigation, parking, music, homeAssistant, translation, health
    // Devices & Privacy
    case glasses, displayBackend, appleWatch, smartRing, hardwarePrivacy, insights, teleprompterOnPhone
    case healthFitness, medicalCompliance, cloudAISharing, processingSummary
    // Accessibility
    case readinessCheck, scanAssist, fingerspelling
    // Look & Feel
    case languages
    // Tools & Actions
    case quickActions, tools, customVaults, personalNotes, studyMode, reading, healthVault, customTools
    case skillPacks, addOns, siriSearch, mcpServer, playbooks, skillStore, voiceSkills, suggestedSkills
    // Connections
    case appleIntegrations, weatherData, services, gateways, mcpServers
    // Capture & Streaming
    case recordings, meetingRecords, captionSessions
    // Display & HUD
    case bandPractice, lensFitCheck, hudMirror, teleprompter
    // Advanced
    case developer, promptInspector, networkActivity, liveVision, documents, captureFlow
    // Diagnostics & Support
    case diagnosticExport

    /// The screen this one is reached through, below its category's own screen, where there is one.
    /// For the "where it lives" line.
    var parent: SettingsScreenID? {
        switch self {
        case .weatherData: return .appleIntegrations
        case .insights, .teleprompterOnPhone: return .hardwarePrivacy
        case .displayBackend: return .glasses
        default: return nil
        }
    }
}

/// Where opening an entry goes.
enum SettingsDestination: Hashable, Sendable {
    /// A category's own screen, through its lock (`SettingsCategoryScreen`). A setting drawn on
    /// that screen opens it.
    case category(SettingsCategoryID)
    /// A screen inside a category.
    case screen(SettingsScreenID)
}

struct SettingsIndexEntry: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case screen
        case setting
    }

    /// Stable: pins store it, so **never change one**.
    let id: String
    let title: String
    let keywords: [String]
    let kind: Kind
    let category: SettingsCategoryID
    let destination: SettingsDestination
    let gate: [SettingsIndexGate]
}

/// What the person in front of the phone may see, captured once per draw. The view builds it from
/// `Config`, `AdminGate` and the services; tests build it by hand.
struct SettingsSearchConditions: Equatable, Sendable {
    var simpleMode: Bool
    var context: ManagedSettingsContext
    var phone: SettingsHubPhone
    var phoneOnlyBuild: Bool
    var assistingPresent: Bool
    var agentMode: Bool
    var fieldAssistUnlocked: Bool
    var fieldAssistOn: Bool
    var watchInstalled: Bool
    var myDayOn: Bool

    init(simpleMode: Bool = false, context: ManagedSettingsContext = .unmanaged,
         phone: SettingsHubPhone = SettingsHubPhone(glassesSupported: true), phoneOnlyBuild: Bool = false,
         assistingPresent: Bool = false, agentMode: Bool = false, fieldAssistUnlocked: Bool = false,
         fieldAssistOn: Bool = false, watchInstalled: Bool = false, myDayOn: Bool = false) {
        self.simpleMode = simpleMode
        self.context = context
        self.phone = phone
        self.phoneOnlyBuild = phoneOnlyBuild
        self.assistingPresent = assistingPresent
        self.agentMode = agentMode
        self.fieldAssistUnlocked = fieldAssistUnlocked
        self.fieldAssistOn = fieldAssistOn
        self.watchInstalled = watchInstalled
        self.myDayOn = myDayOn
    }
}

enum SettingsIndex {

    // MARK: - What is offered

    /// The categories this person can reach, as the hub decides them.
    static func visibleCategories(in conditions: SettingsSearchConditions) -> Set<SettingsCategoryID> {
        Set(SettingsHub.visibleCategories(simpleMode: conditions.simpleMode, in: conditions.context,
                                          on: conditions.phone, assistingPresent: conditions.assistingPresent)
            .map(\.id))
    }

    /// The entries this person may see, in index order.
    static func visible(in conditions: SettingsSearchConditions) -> [SettingsIndexEntry] {
        let categories = visibleCategories(in: conditions)
        return entries.filter { isVisible($0, in: conditions, categories: categories) }
    }

    static func isVisible(_ entry: SettingsIndexEntry, in conditions: SettingsSearchConditions) -> Bool {
        isVisible(entry, in: conditions, categories: visibleCategories(in: conditions))
    }

    private static func isVisible(_ entry: SettingsIndexEntry, in conditions: SettingsSearchConditions,
                                  categories: Set<SettingsCategoryID>) -> Bool {
        guard categories.contains(entry.category),
              SettingsVisibilityPolicy.presentation(.category(entry.category), in: conditions.context).isShown
        else { return false }
        return entry.gate.allSatisfy { holds($0, in: conditions, categories: categories) }
    }

    /// Whether `destination` may be opened now: a screen entry for it is visible. What an opened
    /// result re-checks on every draw. It asks about the screen rather than the setting, so a switch
    /// moved on that very screen (Agentic Features off, say) does not take the screen away under
    /// the person, while a lock, Simple Mode or a profile still does.
    static func opens(_ destination: SettingsDestination, in conditions: SettingsSearchConditions) -> Bool {
        visible(in: conditions).contains { $0.kind == .screen && $0.destination == destination }
    }

    /// `.readOnly` counts as shown: the screens draw a locked protection, locked (decision 3).
    static func holds(_ gate: SettingsIndexGate, in conditions: SettingsSearchConditions) -> Bool {
        holds(gate, in: conditions, categories: visibleCategories(in: conditions))
    }

    private static func holds(_ gate: SettingsIndexGate, in conditions: SettingsSearchConditions,
                              categories: Set<SettingsCategoryID>) -> Bool {
        switch gate {
        case .managed(let setting):
            return SettingsVisibilityPolicy.presentation(setting, in: conditions.context).isShown
        case .groupMember(let id):
            guard let member = SettingsGroupCatalog.member(id) else { return false }
            return SettingsGroupCatalog.presentation(of: member, in: conditions.context).isShown
        case .categoryVisible(let id): return categories.contains(id)
        case .glassesBuild: return !conditions.phoneOnlyBuild
        case .phoneOnlyBuild: return conditions.phoneOnlyBuild
        case .glassesSupported: return conditions.phone.glassesSupported
        case .agentMode: return conditions.agentMode
        case .fieldAssistUnlocked: return conditions.fieldAssistUnlocked
        case .fieldAssistOn: return conditions.fieldAssistOn
        case .watchInstalled: return conditions.watchInstalled
        case .notSimpleMode: return !conditions.simpleMode
        case .myDayOn: return conditions.myDayOn
        case .healthLinkUnderDevices:
            return SettingsGroupCatalog.showsHealthLinkUnderDevices(simpleMode: conditions.simpleMode,
                                                                    in: conditions.context)
        }
    }

    // MARK: - Where it lives

    /// "Assistant › Voice & Triggers": the hub row, then the screens below it. A setting's line
    /// ends with the screen it is on; a screen's line ends with the screen it is reached from.
    static func breadcrumb(for entry: SettingsIndexEntry, on phone: SettingsHubPhone) -> String {
        var parts = SettingsHub.path(to: entry.category, on: phone).components(separatedBy: " > ")
        switch entry.destination {
        case .category:
            // A category's own screen is named by the result itself, so its line is where it sits.
            if entry.kind == .screen, parts.last == entry.title { parts.removeLast() }
            if parts.isEmpty { parts = [String(localized: "Settings")] }
        case .screen(let screen):
            var chain: [SettingsScreenID] = []
            var next = screen.parent
            while let parent = next {
                chain.insert(parent, at: 0)
                next = parent.parent
            }
            if entry.kind == .setting { chain.append(screen) }
            parts += chain.map(title(of:))
        }
        return parts.joined(separator: " › ")
    }

    /// A screen's name: its first screen entry's title.
    static func title(of screen: SettingsScreenID) -> String {
        entries.first { $0.kind == .screen && $0.destination == .screen(screen) }?.title ?? ""
    }

    static func entry(_ id: String) -> SettingsIndexEntry? {
        entries.first { $0.id == id }
    }

    /// Every id in the index. Ids do not change with the language, so this is kept.
    static let ids: Set<String> = Set(entries.map(\.id))

    // MARK: - The index

    /// The whole index, in hub order. Built on demand so titles follow the language. Dynamic rows —
    /// one per vault, per handover, per add-on, per model — are not indexed; their screen is.
    static var entries: [SettingsIndexEntry] {
        intelligence + voice + everyday + devices + accessibility + fieldAssist + assisting
            + lookAndFeel + tools + connections + capture + display + advanced + diagnostics
    }

    private static func screen(_ id: String, _ title: String, _ keywords: String = "",
                               in category: SettingsCategoryID, opens destination: SettingsDestination,
                               gate: [SettingsIndexGate] = []) -> SettingsIndexEntry {
        SettingsIndexEntry(id: id, title: title, keywords: split(keywords), kind: .screen, category: category,
                           destination: destination, gate: gate)
    }

    private static func setting(_ id: String, _ title: String, _ keywords: String = "",
                                in category: SettingsCategoryID, on destination: SettingsDestination? = nil,
                                gate: [SettingsIndexGate] = []) -> SettingsIndexEntry {
        SettingsIndexEntry(id: id, title: title, keywords: split(keywords), kind: .setting, category: category,
                           destination: destination ?? .category(category), gate: gate)
    }

    /// A category's own screen, under the hub's own words for it.
    private static func categoryScreen(_ id: SettingsCategoryID, _ keywords: String,
                                       gate: [SettingsIndexGate] = []) -> SettingsIndexEntry {
        screen("category-\(id.rawValue)", SettingsCatalog.category(id).title, keywords, in: id,
               opens: .category(id), gate: gate)
    }

    private static func split(_ keywords: String) -> [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: AI & Personality

    private static var intelligence: [SettingsIndexEntry] {
        let agentic: [SettingsIndexGate] = [.managed(.key(.agentModeEnabled))]
        return [
            categoryScreen(.intelligence, String(localized: "model, models, AI, persona, prompt, behaviour, behavior", comment: "Settings search keywords, comma-separated")),
            setting("ai-models", String(localized: "AI Models"),
                    String(localized: "API key, key, Claude, Gemini, ChatGPT, OpenAI, add model, provider", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence),
            screen("realtime-models", String(localized: "Realtime Models"),
                   String(localized: "live, Gemini Live, OpenAI Realtime, voice model", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.realtimeModels)),
            setting("end-quiet-session", String(localized: "End a quiet session"),
                    String(localized: "idle, timeout, live session", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence),
            screen("personas", String(localized: "Personas"),
                   String(localized: "character, persona", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.personas)),
            screen("system-prompt", String(localized: "System Prompt"),
                   String(localized: "prompt, instructions, preset", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.systemPrompt)),
            setting("keep-talking-without-signal", String(localized: "Keep Talking Without Signal"),
                    String(localized: "offline, no signal, on-device, local model", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence),
            screen("smart-routing", String(localized: "Smart Routing"),
                   String(localized: "routing, tiers, cheap, fast model", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.smartRouting)),
            setting("auto-model-routing", String(localized: "Auto Model Routing"), in: .intelligence,
                    on: .screen(.smartRouting)),
            setting("model-fallback", String(localized: "Model Fallback"),
                    String(localized: "cascade, rate limit", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence, on: .screen(.smartRouting)),
            setting("stuck-reply", String(localized: "Don't Wait on a Stuck Reply"),
                    String(localized: "slow, timeout", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence, on: .screen(.smartRouting)),
            setting("narrate-model-switches", String(localized: "Narrate Model Switches"), in: .intelligence,
                    on: .screen(.smartRouting)),
            screen("vision-images", String(localized: "Vision Images"),
                   String(localized: "photo, image, resolution, camera", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.visionImages)),
            screen("agentic-features", String(localized: "Agentic Features"),
                   String(localized: "agent, agent mode, autonomous, background tasks", comment: "Settings search keywords, comma-separated"),
                   in: .intelligence, opens: .screen(.agenticFeatures), gate: agentic),
            setting("let-agents-see", String(localized: "Let Agents See"), in: .intelligence,
                    on: .screen(.agenticFeatures), gate: agentic + [.agentMode]),
            setting("run-on-device-model", String(localized: "Run On-Device Model (experimental)"),
                    String(localized: "MLX, local, on-device", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence, on: .screen(.agenticFeatures), gate: agentic + [.agentMode]),
            setting("look-up-tools", String(localized: "Look Up Tools on Demand"),
                    String(localized: "tool definitions, context", comment: "Settings search keywords, comma-separated"),
                    in: .intelligence, gate: [.managed(.key(.organizationToolDefinitionsMode))]),
        ]
    }

    // MARK: Voice & Triggers

    private static var voice: [SettingsIndexEntry] {
        [
            categoryScreen(.voice, String(localized: "wake word, wake phrase, hey, push to talk, triggers", comment: "Settings search keywords, comma-separated")),
            setting("assistant-name", String(localized: "Assistant Name"),
                    String(localized: "name, rename", comment: "Settings search keywords, comma-separated"), in: .voice),
            setting("listen-for-wake-phrase", String(localized: "Listen for Wake Phrase"),
                    String(localized: "wake word, hey, listening, hands-free", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("wake-phrase", String(localized: "Wake Phrase"),
                    String(localized: "wake word, Hey Avenkin, Hey Claude, custom phrase", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("push-to-talk", String(localized: "Push-to-Talk Mode"),
                    String(localized: "push to talk, Action Button, music, podcasts", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("siri-questions", String(localized: "Open App for Siri Questions"),
                    String(localized: "Siri, Hey Siri", comment: "Settings search keywords, comma-separated"), in: .voice),
            setting("quiet-after-actions", String(localized: "Quiet After Actions"),
                    String(localized: "tone, done", comment: "Settings search keywords, comma-separated"),
                    in: .voice, gate: [.notSimpleMode]),
            setting("connecting-cue", String(localized: "Say \"Connecting to Avenkin AI\" at Voice Startup"),
                    String(localized: "startup, announcement", comment: "Settings search keywords, comma-separated"),
                    in: .voice, gate: [.managed(.key(.aiConnectionCueEnabled))]),
            setting("pause-before-answering", String(localized: "Pause Before Answering"),
                    String(localized: "pause, cut off, dictation, wait, silence", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("interrupt-when-you-speak", String(localized: "Interrupt When You Speak"),
                    String(localized: "barge in, interrupt, stop talking", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("one-question-at-a-time", String(localized: "One Question at a Time"),
                    String(localized: "follow-up, mic open", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("check-before-sending", String(localized: "Check what I said before sending"),
                    String(localized: "review, edit, countdown", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("ignore-nearby-chatter", String(localized: "Ignore nearby chatter"),
                    String(localized: "background, TV, noise", comment: "Settings search keywords, comma-separated"),
                    in: .voice),
            setting("hands-free-triggers", String(localized: "Hands-Free Triggers"),
                    String(localized: "shake, trigger", comment: "Settings search keywords, comma-separated"), in: .voice),
            screen("temple-taps", String(localized: "Temple Taps"),
                   String(localized: "tap, touchpad, gesture, media controls", comment: "Settings search keywords, comma-separated"),
                   in: .voice, opens: .screen(.templeTaps), gate: [.glassesBuild]),
        ]
    }

    // MARK: Everyday

    private static var everyday: [SettingsIndexEntry] {
        func member(_ id: SettingsGroupMemberID) -> [SettingsIndexGate] { [.groupMember(id)] }
        return [
            categoryScreen(.everyday, String(localized: "memory, My Day, routines, navigation, home, music, messages, translation, health", comment: "Settings search keywords, comma-separated")),
            // Memory
            setting("user-memory", String(localized: "User Memory"),
                    String(localized: "remember, facts", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.userMemory)),
            screen("what-avenkin-remembers", String(localized: "What Avenkin Remembers"),
                   String(localized: "memory, memories, facts, forget", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.memory), gate: member(.whatAvenkinRemembers)),
            setting("conversation-history", String(localized: "Conversation History"),
                    String(localized: "history, transcripts", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.conversationHistory)),
            setting("remember-earlier", String(localized: "Remember Earlier in Long Conversations"),
                    String(localized: "long conversations, context", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.earlierInConversation)),
            setting("conversation-notes", String(localized: "Notes of Finished Conversations"),
                    String(localized: "digest, summary", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.conversationNotes)),
            setting("memory-suggestions", String(localized: "Memory Suggestions"),
                    String(localized: "nudges", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.memorySuggestions)),
            screen("goals", String(localized: "Goals"),
                   String(localized: "unfinished things", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.goals), gate: member(.goals)),
            screen("activity", String(localized: "Activity"), in: .everyday, opens: .screen(.activity),
                   gate: member(.activity)),
            setting("memory-enrichment", String(localized: "Memory Enrichment"),
                    String(localized: "relationships", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.memoryEnrichment)),
            // My Day & Routines
            setting("my-day", String(localized: "My Day"),
                    String(localized: "briefing, morning, daily summary", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.myDay)),
            setting("my-day-on-home", String(localized: "Show on Home Screen"),
                    String(localized: "My Day, home", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.myDayContents) + [.myDayOn]),
            screen("my-day-contents", String(localized: "What's in My Day"),
                   String(localized: "briefing, calendar, weather", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.myDayContents), gate: member(.myDayContents) + [.myDayOn]),
            screen("ready-to-send-cards", String(localized: "Ready-to-send cards"),
                   String(localized: "cards, My Day", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.preparedCards), gate: member(.myDayContents) + [.myDayOn]),
            screen("scheduled-delivery", String(localized: "Scheduled Delivery"),
                   String(localized: "My Day, alarm, schedule", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.myDayDelivery), gate: member(.myDayDelivery) + [.myDayOn]),
            screen("scheduled-tasks", String(localized: "Scheduled Tasks"),
                   String(localized: "recurring, automation", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.scheduledTasks), gate: member(.scheduledTasks) + [.agentMode]),
            // Getting Around
            screen("walking-navigation", String(localized: "Walking Navigation"),
                   String(localized: "directions, maps, walking, route, turn by turn", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.navigation), gate: member(.navigation)),
            screen("parking", String(localized: "Parking"),
                   String(localized: "car, parked", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.parking), gate: member(.parking)),
            // Home, Music & Messages
            setting("smart-home-control", String(localized: "AI Smart Home Control"),
                    String(localized: "HomeKit, lights", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.smartHome)),
            setting("ai-messaging", String(localized: "AI Messaging"),
                    String(localized: "messages, text, iMessage, WhatsApp", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.messaging)),
            screen("music-podcasts", String(localized: "Music & Podcasts"),
                   String(localized: "Spotify, Apple Music", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.music), gate: member(.music)),
            screen("home-assistant", String(localized: "Home Assistant"),
                   String(localized: "smart home", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.homeAssistant), gate: member(.homeAssistant)),
            // Translate
            screen("translation", String(localized: "Translation"),
                   String(localized: "translate, interpreter, language", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.translation), gate: member(.translation)),
            // Health & Fitness
            screen("health", String(localized: "Health"),
                   String(localized: "Apple Health, HealthKit, fitness", comment: "Settings search keywords, comma-separated"),
                   in: .everyday, opens: .screen(.health), gate: member(.health)),
            setting("ai-health-vault", String(localized: "AI Access to Health Vault"), in: .everyday,
                    on: .screen(.health), gate: member(.health) + [.managed(.tool("health_vault"))]),
            setting("health-summaries", String(localized: "Health Summaries"),
                    String(localized: "steps, sleep", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.healthSummaries)),
            setting("first-aid", String(localized: "First-Aid Coaching and Triage"),
                    String(localized: "first aid, emergency, CPR", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.firstAid)),
            setting("share-health", String(localized: "Share Health Data with AI"),
                    String(localized: "Apple Health, privacy", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: member(.shareHealth)),
            setting("private-conversations", String(localized: "Private conversations"),
                    String(localized: "off the record", comment: "Settings search keywords, comma-separated"),
                    in: .everyday, gate: [.managed(.key(.privateConversationsAllowed))]),
            // My Manuals is a row of Everyday's screen, and a category of its own.
            categoryScreen(.myManuals, String(localized: "manuals, PDF, documents, guides", comment: "Settings search keywords, comma-separated")),
        ]
    }

    // MARK: Devices & Privacy

    private static var devices: [SettingsIndexEntry] {
        let glasses: [SettingsIndexGate] = [.glassesBuild, .glassesSupported, .managed(.area(.glasses))]
        let rest: [SettingsIndexGate] = [.managed(.row(in: .devices))]
        let routing: [SettingsIndexGate] = [.managed(.area(.requestRouting))]
        return [
            categoryScreen(.devices, String(localized: "privacy, hardware, glasses, microphone, medical", comment: "Settings search keywords, comma-separated")),
            // Glasses
            screen("glasses", String(localized: "Glasses"),
                   String(localized: "Ray-Ban, Meta, connect, pair, firmware", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.glasses), gate: glasses),
            setting("wake-listen-mic", String(localized: "Listen for the wake word on"),
                    String(localized: "wake word, glasses mic, iPhone mic", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses),
            setting("reply-audio", String(localized: "Reply audio"),
                    String(localized: "call quality, full quality, Bluetooth", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses),
            setting("sleep-when-quiet", String(localized: "Sleep When Quiet, Even While Worn"),
                    String(localized: "sleep, battery, worn", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses),
            setting("update-glasses-app", String(localized: "Update Glasses App"),
                    String(localized: "update, companion app", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses),
            setting("update-glasses-firmware", String(localized: "Update Glasses Firmware"),
                    String(localized: "firmware, update", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses),
            setting("instant-replay", String(localized: "Instant Replay"),
                    String(localized: "replay, last 30 seconds, clip", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.glasses), gate: glasses + [.managed(.key(.instantReplayEnabled))]),
            screen("display-backend", String(localized: "Display Backend"),
                   String(localized: "EVEN G2, display glasses, lens", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.displayBackend), gate: glasses + [.categoryVisible(.display)]),
            // Wearables
            screen("apple-watch", String(localized: "Apple Watch"),
                   String(localized: "watch, wrist, map cards", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.appleWatch), gate: rest + [.watchInstalled]),
            screen("smart-ring", String(localized: "Smart Ring"),
                   String(localized: "ring, heart rate, blood oxygen, sleep, steps", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.smartRing), gate: rest + [.glassesBuild]),
            // Hardware & Privacy
            screen("hardware-privacy", String(localized: "Hardware & Privacy"),
                   String(localized: "mic, privacy, encryption, history", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.hardwarePrivacy), gate: rest),
            setting("microphone", String(localized: "Microphone"),
                    String(localized: "mic, headset, AirPods, glasses mic, iPhone mic", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest),
            setting("audio-only-mode", String(localized: "Audio-Only Mode"),
                    String(localized: "camera off, battery", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest + [.glassesBuild]),
            setting("dwell-capture", String(localized: "Dwell Capture"),
                    String(localized: "gaze, photo", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest + [.glassesBuild]),
            setting("phone-mic-translation", String(localized: "Use Phone Mic for Translation"), in: .devices,
                    on: .screen(.hardwarePrivacy), gate: rest + [.glassesBuild]),
            setting("glasses-only-audio", String(localized: "Glasses Only Audio"),
                    String(localized: "speaker, silent, sounds", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest + [.glassesBuild]),
            setting("voice-isolation", String(localized: "Voice Isolation Mode"),
                    String(localized: "noise, noise cancellation, mic mode", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest),
            setting("blur-bystander-faces", String(localized: "Blur Bystander Faces"),
                    String(localized: "blur, faces, privacy filter, bystanders", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy),
                    gate: rest + [.managed(.key(.privacyFilterEnabled))]),
            setting("encrypt-conversations", String(localized: "Encrypt Conversations"),
                    String(localized: "encryption, Face ID, passcode", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest),
            setting("keep-history-for", String(localized: "Keep History For"),
                    String(localized: "retention, delete, forever", comment: "Settings search keywords, comma-separated"),
                    in: .devices, on: .screen(.hardwarePrivacy), gate: rest),
            screen("insights", String(localized: "Insights"),
                   String(localized: "stats, charts, usage", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.insights), gate: rest),
            screen("teleprompter-phone", String(localized: "Teleprompter"),
                   String(localized: "script, autocue", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.teleprompterOnPhone), gate: rest + [.phoneOnlyBuild]),
            // Health & Fitness, where Everyday is not on the hub.
            screen("health-fitness-devices", String(localized: "Health & Fitness"),
                   String(localized: "health, first aid, fitness", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.healthFitness), gate: rest + [.healthLinkUnderDevices]),
            screen("medical-compliance", String(localized: "Medical Compliance"),
                   String(localized: "HIPAA, medical, clinical, compliance", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.medicalCompliance), gate: rest),
            // Where your requests go
            screen("cloud-ai-sharing", String(localized: "Cloud AI Sharing"),
                   String(localized: "cloud, consent, sharing, provider", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.cloudAISharing), gate: routing),
            screen("requests-processed", String(localized: "How Your Requests Are Processed"),
                   String(localized: "where data goes, routing, offline", comment: "Settings search keywords, comma-separated"),
                   in: .devices, opens: .screen(.processingSummary), gate: routing),
        ]
    }

    // MARK: Accessibility

    private static var accessibility: [SettingsIndexEntry] {
        [
            categoryScreen(.accessibility, String(localized: "blind, low vision, VoiceOver, reading, narration", comment: "Settings search keywords, comma-separated")),
            setting("reading-accessibility", String(localized: "Enable Reading Accessibility"),
                    String(localized: "read text, OCR, simplify, reading level, Social Mode, Assistive Mode", comment: "Settings search keywords, comma-separated"),
                    in: .accessibility),
            setting("scene-narration", String(localized: "Enable Scene Narration"),
                    String(localized: "describe, surroundings, blind", comment: "Settings search keywords, comma-separated"),
                    in: .accessibility, gate: [.glassesBuild]),
            setting("blind-assistant-on-open", String(localized: "Start Blind Assistant When I Open the App"),
                    String(localized: "launch, start", comment: "Settings search keywords, comma-separated"),
                    in: .accessibility),
            screen("readiness-check", String(localized: "Check the Assistant Is Ready"),
                   String(localized: "readiness, test", comment: "Settings search keywords, comma-separated"),
                   in: .accessibility, opens: .screen(.readinessCheck)),
            screen("requests-processed-accessibility", String(localized: "How Your Requests Are Processed"),
                   String(localized: "where data goes, routing, offline", comment: "Settings search keywords, comma-separated"),
                   in: .accessibility, opens: .screen(.processingSummary)),
            setting("spoken-cues", String(localized: "Speak What Each Sound Means"),
                    String(localized: "sounds, cues", comment: "Settings search keywords, comma-separated"),
                    in: .accessibility),
            screen("scan-assist", String(localized: "Scan Assist"),
                   String(localized: "left, right, reminders", comment: "Settings search keywords, comma-separated"),
                   in: .accessibility, opens: .screen(.scanAssist)),
            screen("fingerspelling", String(localized: "Fingerspelling"),
                   String(localized: "ASL, sign language", comment: "Settings search keywords, comma-separated"),
                   in: .accessibility, opens: .screen(.fingerspelling), gate: [.glassesBuild]),
        ]
    }

    // MARK: Field Assist

    private static var fieldAssist: [SettingsIndexEntry] {
        let on: [SettingsIndexGate] = [.fieldAssistOn]
        return [
            categoryScreen(.fieldAssist, String(localized: "jobs, vaults, technician, trade", comment: "Settings search keywords, comma-separated")),
            setting("enable-field-assist", String(localized: "Enable Field Assist"), in: .fieldAssist,
                    gate: [.managed(.area(.fieldAssistSwitch))]),
            setting("workiz", String(localized: "Workiz"),
                    String(localized: "field service software", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: [.fieldAssistUnlocked]),
            setting("stock-system", String(localized: "Stock system"),
                    String(localized: "stock, inventory, parts", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: [.fieldAssistUnlocked]),
            setting("default-vault", String(localized: "Default Vault"), in: .fieldAssist, gate: on),
            setting("reference-files", String(localized: "Reference Files"), in: .fieldAssist, gate: on),
            setting("manual-search", String(localized: "Manual Search"),
                    String(localized: "search model, manuals", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: on),
            setting("field-sync", String(localized: "Field Sync"),
                    String(localized: "sync, offline, queue", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: on),
            setting("default-session-mode", String(localized: "Default Session Mode"), in: .fieldAssist, gate: on),
            setting("time-billing", String(localized: "Time Billing"),
                    String(localized: "billing, units", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: on),
            setting("experts", String(localized: "Experts"),
                    String(localized: "expert, help", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: on),
            setting("expert-stream-transport", String(localized: "Expert Stream Transport"),
                    String(localized: "WebRTC, MJPEG, meeting link", comment: "Settings search keywords, comma-separated"),
                    in: .fieldAssist, gate: on),
        ]
    }

    // MARK: Assisting

    private static var assisting: [SettingsIndexEntry] {
        [categoryScreen(.assisting, String(localized: "expert, expert card", comment: "Settings search keywords, comma-separated"))]
    }

    // MARK: Look & Feel

    private static var lookAndFeel: [SettingsIndexEntry] {
        [
            categoryScreen(.lookAndFeel, String(localized: "theme, dark mode, colour, color, language", comment: "Settings search keywords, comma-separated")),
            setting("theme", String(localized: "Theme"),
                    String(localized: "dark, dark mode, light, appearance", comment: "Settings search keywords, comma-separated"),
                    in: .lookAndFeel),
            setting("accent-colour", String(localized: "Accent Colour"),
                    String(localized: "color, colour, tint", comment: "Settings search keywords, comma-separated"),
                    in: .lookAndFeel),
            screen("languages", String(localized: "Languages"),
                   String(localized: "language, download", comment: "Settings search keywords, comma-separated"),
                   in: .lookAndFeel, opens: .screen(.languages)),
        ]
    }

    // MARK: Tools & Actions

    private static var tools: [SettingsIndexEntry] {
        [
            categoryScreen(.tools, String(localized: "tools, actions, skills, playbooks", comment: "Settings search keywords, comma-separated")),
            screen("quick-actions", String(localized: "Quick Actions"),
                   String(localized: "widget, shortcuts", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.quickActions)),
            screen("tools", String(localized: "Tools"),
                   String(localized: "built-in tools, capabilities", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.tools)),
            setting("offline-mode", String(localized: "Offline Mode"),
                    String(localized: "aeroplane, airplane, no internet", comment: "Settings search keywords, comma-separated"),
                    in: .tools, on: .screen(.tools)),
            screen("custom-vaults", String(localized: "Custom Vaults"), in: .tools, opens: .screen(.customVaults)),
            screen("personal-notes", String(localized: "Personal Notes"),
                   String(localized: "notes", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.personalNotes)),
            screen("study-mode", String(localized: "Study Mode"),
                   String(localized: "flashcards, decks", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.studyMode)),
            screen("reading", String(localized: "Reading"),
                   String(localized: "books", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.reading), gate: [.glassesBuild]),
            screen("health-vault", String(localized: "Health Vault"),
                   String(localized: "medical records, medications", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.healthVault)),
            screen("custom-tools", String(localized: "Custom Tools"),
                   String(localized: "script, webhook", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.customTools)),
            screen("skill-packs", String(localized: "Skill Packs"), in: .tools, opens: .screen(.skillPacks)),
            screen("add-ons", String(localized: "Add-ons"),
                   String(localized: "plugins, extensions", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.addOns)),
            screen("siri-search", String(localized: "Siri & Search"),
                   String(localized: "Siri, Shortcuts, Spotlight", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.siriSearch)),
            screen("mcp-server", String(localized: "MCP Server"),
                   String(localized: "Mac, server", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.mcpServer),
                   gate: [.glassesBuild, .agentMode, .managed(.key(.mcpServerEnabled))]),
            screen("playbooks", String(localized: "Playbooks"),
                   String(localized: "routines, scripts, automation", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.playbooks)),
            screen("skill-store", String(localized: "Skill Store"),
                   String(localized: "ClawHub, skills, community", comment: "Settings search keywords, comma-separated"),
                   in: .tools, opens: .screen(.skillStore)),
            screen("voice-skills", String(localized: "Voice Skills"), in: .tools, opens: .screen(.voiceSkills)),
            screen("suggested-skills", String(localized: "Suggested Skills"), in: .tools,
                   opens: .screen(.suggestedSkills), gate: [.agentMode]),
        ]
    }

    // MARK: Connections

    private static var connections: [SettingsIndexEntry] {
        [
            categoryScreen(.connections, String(localized: "apps, services, integrations, gateways, MCP", comment: "Settings search keywords, comma-separated")),
            screen("works-with-iphone", String(localized: "Works with your iPhone"),
                   String(localized: "Calendar, Reminders, Contacts, HomeKit, Alarms, Maps, Apple apps", comment: "Settings search keywords, comma-separated"),
                   in: .connections, opens: .screen(.appleIntegrations)),
            screen("weather-data", String(localized: "About Weather Data"),
                   String(localized: "weather", comment: "Settings search keywords, comma-separated"),
                   in: .connections, opens: .screen(.weatherData)),
            screen("services", String(localized: "Services & Integrations"),
                   String(localized: "ElevenLabs, voices, web search, Perplexity", comment: "Settings search keywords, comma-separated"),
                   in: .connections, opens: .screen(.services)),
            screen("gateways", String(localized: "Gateways"),
                   String(localized: "OpenClaw, Hermes, agents", comment: "Settings search keywords, comma-separated"),
                   in: .connections, opens: .screen(.gateways)),
            screen("mcp-servers", String(localized: "MCP Servers"),
                   String(localized: "tool servers", comment: "Settings search keywords, comma-separated"),
                   in: .connections, opens: .screen(.mcpServers)),
        ]
    }

    // MARK: Capture & Streaming

    private static var capture: [SettingsIndexEntry] {
        [
            categoryScreen(.capture, String(localized: "record, recording, meetings, stream, live", comment: "Settings search keywords, comma-separated")),
            screen("recordings", String(localized: "Recordings"),
                   String(localized: "video, audio, playback, transcripts", comment: "Settings search keywords, comma-separated"),
                   in: .capture, opens: .screen(.recordings)),
            screen("meeting-records", String(localized: "Meeting Records"),
                   String(localized: "meeting summary, minutes", comment: "Settings search keywords, comma-separated"),
                   in: .capture, opens: .screen(.meetingRecords)),
            screen("caption-sessions", String(localized: "Caption Sessions"),
                   String(localized: "captions, subtitles", comment: "Settings search keywords, comma-separated"),
                   in: .capture, opens: .screen(.captionSessions)),
            screen("camera-recording-streaming", String(localized: "Camera, Recording & Streaming"),
                   String(localized: "go live, broadcast, RTMP, YouTube, Twitch, stream key", comment: "Settings search keywords, comma-separated"),
                   in: .capture, opens: .screen(.services)),
        ]
    }

    // MARK: Display & HUD

    private static var display: [SettingsIndexEntry] {
        // Reached through Devices & Privacy › Glasses.
        let viaGlasses: [SettingsIndexGate] = [.managed(.area(.glasses))]
        let lens = viaGlasses + [.glassesBuild]
        let hud = SettingsDestination.category(.display)
        return [
            categoryScreen(.display, String(localized: "HUD, lens, display, Ray-Ban Display", comment: "Settings search keywords, comma-separated"),
                           gate: viaGlasses),
            setting("glasses-display-hud", String(localized: "Glasses Display (HUD)"), in: .display, on: hud, gate: lens),
            setting("hud-choice-buttons", String(localized: "HUD Choice Buttons"),
                    String(localized: "buttons, Neural Band, options", comment: "Settings search keywords, comma-separated"),
                    in: .display, on: hud, gate: lens),
            setting("lens-keeps-phone-mic", String(localized: "Keep the mic on the iPhone while the display is on"),
                    String(localized: "mic, call screen", comment: "Settings search keywords, comma-separated"),
                    in: .display, on: hud, gate: lens),
            setting("display-busy-hint", String(localized: "Say when the display is busy"), in: .display, on: hud,
                    gate: lens),
            setting("follow-ups-on-display", String(localized: "Suggested follow-ups on the display"), in: .display,
                    on: hud, gate: lens),
            setting("answers-on-lens", String(localized: "Answers on the lens"),
                    String(localized: "scroll, pages", comment: "Settings search keywords, comma-separated"),
                    in: .display, on: hud, gate: lens),
            setting("highlight-colour", String(localized: "Highlight colour"),
                    String(localized: "color, colour, marks", comment: "Settings search keywords, comma-separated"),
                    in: .display, on: hud, gate: lens),
            screen("practise-band", String(localized: "Practise the band"),
                   String(localized: "Neural Band, practice, gestures", comment: "Settings search keywords, comma-separated"),
                   in: .display, opens: .screen(.bandPractice), gate: lens),
            screen("fit-check", String(localized: "Fit check"),
                   String(localized: "fit, lens", comment: "Settings search keywords, comma-separated"),
                   in: .display, opens: .screen(.lensFitCheck), gate: lens),
            screen("hud-mirror", String(localized: "HUD Mirror (phone preview)"),
                   String(localized: "preview, mirror", comment: "Settings search keywords, comma-separated"),
                   in: .display, opens: .screen(.hudMirror), gate: lens),
            screen("teleprompter", String(localized: "Teleprompter"),
                   String(localized: "script, autocue", comment: "Settings search keywords, comma-separated"),
                   in: .display, opens: .screen(.teleprompter), gate: viaGlasses),
        ]
    }

    // MARK: Advanced

    private static var advanced: [SettingsIndexEntry] {
        [
            categoryScreen(.advanced, String(localized: "developer, debug, power user", comment: "Settings search keywords, comma-separated")),
            screen("developer", String(localized: "Developer"),
                   String(localized: "debug, logs", comment: "Settings search keywords, comma-separated"),
                   in: .advanced, opens: .screen(.developer)),
            screen("prompt-inspector", String(localized: "Prompt Inspector"), in: .advanced,
                   opens: .screen(.promptInspector)),
            screen("network-activity", String(localized: "Network Activity"),
                   String(localized: "network, requests, traffic", comment: "Settings search keywords, comma-separated"),
                   in: .advanced, opens: .screen(.networkActivity)),
            screen("live-vision", String(localized: "Live Vision"), in: .advanced, opens: .screen(.liveVision)),
            screen("documents", String(localized: "Documents"), in: .advanced, opens: .screen(.documents)),
            screen("capture-flow", String(localized: "Author Capture-Flow"), in: .advanced,
                   opens: .screen(.captureFlow)),
        ]
    }

    // MARK: Diagnostics & Support

    private static var diagnostics: [SettingsIndexEntry] {
        let ownerControls: [SettingsIndexGate] = [.managed(.area(.ownerControls)), .notSimpleMode]
        return [
            categoryScreen(.diagnostics, String(localized: "support, help, report, bug, self-test", comment: "Settings search keywords, comma-separated")),
            setting("simple-mode", String(localized: "Simple Mode"),
                    String(localized: "caretaker, hand over", comment: "Settings search keywords, comma-separated"),
                    in: .diagnostics, gate: ownerControls),
            setting("lock-settings", String(localized: "Lock Settings"),
                    String(localized: "Face ID, passcode", comment: "Settings search keywords, comma-separated"),
                    in: .diagnostics, gate: ownerControls),
            setting("support-email", String(localized: "Support email"), in: .diagnostics),
            setting("send-todays-activity", String(localized: "Send Today's Activity"), in: .diagnostics),
            setting("run-diagnostics", String(localized: "Run Diagnostics"),
                    String(localized: "self-test, test", comment: "Settings search keywords, comma-separated"),
                    in: .diagnostics),
            setting("report-a-problem", String(localized: "Report a Problem"),
                    String(localized: "bug, problem", comment: "Settings search keywords, comma-separated"),
                    in: .diagnostics),
            screen("export-diagnostics", String(localized: "Export Diagnostics"),
                   String(localized: "diagnostics file, log", comment: "Settings search keywords, comma-separated"),
                   in: .diagnostics, opens: .screen(.diagnosticExport)),
            setting("delete-ai-turn-records", String(localized: "Delete AI Turn Records"),
                    String(localized: "turn records, traces", comment: "Settings search keywords, comma-separated"),
                    in: .diagnostics),
        ]
    }
}

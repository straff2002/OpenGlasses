import XCTest
@testable import OpenGlasses

/// Plan NE P2 — the settings index: nothing hidden leaks into it, it stays complete as screens and
/// switches are added, and its ids never change. Pure — no `.shared`.
final class SettingsIndexTests: XCTestCase {

    // MARK: - Who is looking

    static func technician(_ lockdown: ManagedLockdown = .standard,
                           keys: Set<SettingKey> = []) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: true, lockedKeys: keys)
    }

    static func administrator(_ lockdown: ManagedLockdown = .standard) -> ManagedSettingsContext {
        ManagedSettingsContext(managed: true, lockdown: lockdown, restricted: false, lockedKeys: [])
    }

    static let lockEverything = ManagedLockdown(opening: [], locking: Set(SettingsCategoryID.allCases),
                                                closedTools: [])
    /// Some categories opened, a tool closed, and keys pinned — the technician sees part of a lot.
    static let partlyOpen = ManagedLockdown(opening: [.everyday, .voice, .intelligence, .tools, .display],
                                            locking: [], closedTools: ["health_vault", "web_search"])
    static let pinnedKeys: Set<SettingKey> = [.agentModeEnabled, .privacyFilterEnabled, .aiConnectionCueEnabled,
                                              .mcpServerEnabled, .organizationToolDefinitionsMode,
                                              .instantReplayEnabled, .privateConversationsAllowed]
    static let ceilingsOnly = ManagedSettingsContext(managed: true, lockdown: nil, restricted: false,
                                                     lockedKeys: [.agentModeEnabled, .instantReplayEnabled])

    static var contexts: [(name: String, context: ManagedSettingsContext)] {
        [("unmanaged", .unmanaged),
         ("technician", technician()),
         ("technician, all locked", technician(lockEverything)),
         ("technician, partly open", technician(partlyOpen, keys: pinnedKeys)),
         ("administrator", administrator()),
         ("administrator, partly open", administrator(partlyOpen)),
         ("ceilings only", ceilingsOnly)]
    }

    /// Every combination the plan names, with the runtime switches all on (the most an index can
    /// offer) and all off.
    static var everyCondition: [(name: String, conditions: SettingsSearchConditions)] {
        var all: [(String, SettingsSearchConditions)] = []
        for (name, context) in contexts {
            for simpleMode in [false, true] {
                for glasses in [true, false] {
                    for phoneOnly in [false, true] {
                        for switches in [true, false] {
                            all.append(("\(name), simple \(simpleMode), glasses \(glasses), phone-only \(phoneOnly), "
                                            + "switches \(switches)",
                                        SettingsSearchConditions(
                                            simpleMode: simpleMode, context: context,
                                            phone: SettingsHubPhone(glassesSupported: glasses),
                                            phoneOnlyBuild: phoneOnly, assistingPresent: switches,
                                            agentMode: switches, fieldAssistUnlocked: switches,
                                            fieldAssistOn: switches, watchInstalled: switches, myDayOn: switches)))
                        }
                    }
                }
            }
        }
        return all
    }

    private func ids(_ conditions: SettingsSearchConditions) -> Set<String> {
        Set(SettingsIndex.visible(in: conditions).map(\.id))
    }

    private let everythingOn = SettingsSearchConditions(assistingPresent: true, agentMode: true,
                                                        fieldAssistUnlocked: true, fieldAssistOn: true,
                                                        watchInstalled: true, myDayOn: true)

    // MARK: - Nothing hidden leaks

    func testNoVisibleEntryBelongsToAHiddenCategoryOrCarriesAHiddenSetting() {
        for (name, conditions) in Self.everyCondition {
            let categories = SettingsHub.visibleCategories(simpleMode: conditions.simpleMode, in: conditions.context,
                                                           on: conditions.phone,
                                                           assistingPresent: conditions.assistingPresent).map(\.id)
            for entry in SettingsIndex.visible(in: conditions) {
                XCTAssertTrue(categories.contains(entry.category), "\(entry.id) in a hidden category — \(name)")
                XCTAssertTrue(SettingsVisibilityPolicy.presentation(.category(entry.category),
                                                                    in: conditions.context).isShown, name)
                for gate in entry.gate {
                    switch gate {
                    case .managed(let setting):
                        XCTAssertTrue(SettingsVisibilityPolicy.presentation(setting, in: conditions.context).isShown,
                                      "\(entry.id) carries hidden \(setting) — \(name)")
                    case .groupMember(let id):
                        let member = SettingsGroupCatalog.member(id)!
                        XCTAssertTrue(SettingsGroupCatalog.presentation(of: member, in: conditions.context).isShown,
                                      "\(entry.id): \(id) is hidden — \(name)")
                    case .glassesBuild: XCTAssertFalse(conditions.phoneOnlyBuild, "\(entry.id) — \(name)")
                    case .phoneOnlyBuild: XCTAssertTrue(conditions.phoneOnlyBuild, "\(entry.id) — \(name)")
                    case .glassesSupported: XCTAssertTrue(conditions.phone.glassesSupported, "\(entry.id) — \(name)")
                    case .notSimpleMode: XCTAssertFalse(conditions.simpleMode, "\(entry.id) — \(name)")
                    case .agentMode: XCTAssertTrue(conditions.agentMode, "\(entry.id) — \(name)")
                    case .categoryVisible(let other): XCTAssertTrue(categories.contains(other), "\(entry.id) — \(name)")
                    default: break
                    }
                }
            }
        }
    }

    func testSearchResultsAndPinsNeverReachBeyondWhatIsVisible() {
        let everyID = SettingsIndex.entries.map(\.id)
        let queries = ["a", "e", "memory", "glasses", "blur", "privacy", "agent", "display", "hipaa", "wake word",
                       "devices", "settings", "tools", "simple"]
        for (name, conditions) in Self.everyCondition {
            let visible = ids(conditions)
            for query in queries {
                let found = Set(SettingsSearch.results(for: query, in: conditions).map(\.id))
                XCTAssertTrue(found.isSubset(of: visible), "\(query): \(found.subtracting(visible)) — \(name)")
            }
            let pinned = Set(SettingsPins(ids: Array(everyID.prefix(8))).visible(in: conditions).map(\.id))
            XCTAssertTrue(pinned.isSubset(of: visible), name)
            let lastPinned = Set(SettingsPins(ids: Array(everyID.suffix(8))).visible(in: conditions).map(\.id))
            XCTAssertTrue(lastPinned.isSubset(of: visible), name)
        }
    }

    /// An opened result re-checks its screen; every offered entry's screen must be openable then.
    func testEveryVisibleEntryOpensItsScreen() {
        for (name, conditions) in Self.everyCondition {
            for entry in SettingsIndex.visible(in: conditions) {
                XCTAssertTrue(SettingsIndex.opens(entry.destination, in: conditions), "\(entry.id) — \(name)")
            }
        }
    }

    func testATechnicianSeesNoLockedCategoryAndNoLockedRow() {
        let locked = SettingsCategoryID.allCases.filter {
            SettingsVisibilityPolicy.presentation(.category($0), in: Self.technician()) == .hidden
        }
        XCTAssertFalse(locked.isEmpty)
        let visible = SettingsIndex.visible(in: SettingsSearchConditions(context: Self.technician()))
        for entry in visible { XCTAssertFalse(locked.contains(entry.category), entry.id) }
        // Devices & Privacy is partly open: Glasses and the routing disclosure, not Hardware & Privacy.
        let shown = Set(visible.map(\.id))
        XCTAssertTrue(shown.contains("glasses"))
        XCTAssertTrue(shown.contains("requests-processed"))
        XCTAssertFalse(shown.contains("hardware-privacy"))
        XCTAssertFalse(shown.contains("blur-bystander-faces"))
        XCTAssertFalse(shown.contains("medical-compliance"))
    }

    func testAnAdministratorSeesWhatTheLockdownLocks() {
        let shown = ids(SettingsSearchConditions(context: Self.administrator()))
        XCTAssertTrue(shown.contains("hardware-privacy"))
        XCTAssertTrue(shown.contains("category-intelligence"))
    }

    func testAPinnedKeyIsHiddenFromTheTechnicianUnlessItMustBeSeen() {
        let shown = ids(SettingsSearchConditions(context: Self.ceilingsOnly, agentMode: true))
        XCTAssertFalse(shown.contains("agentic-features"), "a page whose only control is pinned is not linked")
        XCTAssertFalse(shown.contains("let-agents-see"))
        // Instant Replay pinned off is drawn read-only, so it is still found.
        XCTAssertTrue(shown.contains("instant-replay"))
        XCTAssertTrue(ids(SettingsSearchConditions(agentMode: true)).contains("let-agents-see"))
    }

    func testAClosedToolTakesItsSwitchAway() {
        let context = Self.technician(ManagedLockdown(opening: [.everyday], locking: [],
                                                       closedTools: ["health_vault"]))
        let shown = ids(SettingsSearchConditions(context: context))
        XCTAssertTrue(shown.contains("health"))
        XCTAssertFalse(shown.contains("ai-health-vault"))
    }

    func testSimpleModeOffersOnlyWhatSimpleModeKeeps() {
        let simple = SettingsSearchConditions(simpleMode: true, assistingPresent: true, agentMode: true,
                                              watchInstalled: true, myDayOn: true)
        let kept = Set(SettingsCatalog.visible(simpleMode: true).map(\.id))
        let visible = SettingsIndex.visible(in: simple)
        for entry in visible { XCTAssertTrue(kept.contains(entry.category), entry.id) }
        let shown = Set(visible.map(\.id))
        XCTAssertFalse(shown.contains("quiet-after-actions"), "never offered in Simple Mode")
        XCTAssertFalse(shown.contains("simple-mode"), "the hub has Leave Simple Mode instead")
        XCTAssertFalse(shown.contains("lock-settings"))
        XCTAssertTrue(shown.contains("category-accessibility"))
        XCTAssertTrue(ids(SettingsSearchConditions()).contains("quiet-after-actions"))
    }

    func testThePhoneOnlyBuildOffersNoGlassesScreen() {
        let glassesOnly: Set<SettingsScreenID> = [.glasses, .displayBackend, .smartRing, .templeTaps, .reading,
                                                  .mcpServer, .bandPractice, .lensFitCheck, .hudMirror,
                                                  .fingerspelling]
        var phoneOnly = everythingOn
        phoneOnly.phoneOnlyBuild = true
        phoneOnly.phone = SettingsHubPhone(glassesSupported: false)
        let visible = SettingsIndex.visible(in: phoneOnly)
        for entry in visible {
            XCTAssertNotEqual(entry.category, .display, entry.id)
            if case .screen(let screen) = entry.destination {
                XCTAssertFalse(glassesOnly.contains(screen), entry.id)
            }
        }
        let shown = Set(visible.map(\.id))
        XCTAssertTrue(shown.contains("teleprompter-phone"), "the teleprompter is under Hardware & Privacy there")
        XCTAssertFalse(shown.contains("teleprompter"))
        XCTAssertFalse(ids(everythingOn).contains("teleprompter-phone"))
        XCTAssertTrue(ids(everythingOn).contains("teleprompter"))
    }

    func testACopyWithoutGlassesOffersNoDisplayOrGlassesScreen() {
        var noGlasses = everythingOn
        noGlasses.phone = SettingsHubPhone(glassesSupported: false)
        let shown = ids(noGlasses)
        XCTAssertFalse(shown.contains("glasses"))
        XCTAssertFalse(shown.contains("display-backend"))
        XCTAssertFalse(shown.contains("category-display"))
        XCTAssertFalse(shown.contains("glasses-display-hud"))
        XCTAssertTrue(ids(everythingOn).isSuperset(of: ["glasses", "display-backend", "glasses-display-hud"]))
    }

    func testRuntimeSwitchesGateTheirScreens() {
        let off = ids(SettingsSearchConditions())
        let on = ids(everythingOn)
        for id in ["scheduled-tasks", "suggested-skills", "mcp-server", "let-agents-see", "run-on-device-model",
                   "my-day-contents", "scheduled-delivery", "my-day-on-home", "apple-watch", "field-sync",
                   "experts", "workiz", "category-assisting"] {
            XCTAssertFalse(off.contains(id), id)
            XCTAssertTrue(on.contains(id), id)
        }
        XCTAssertTrue(off.contains("agentic-features"), "its own switch is on it")
        XCTAssertTrue(off.contains("enable-field-assist"))
    }

    func testHealthAndFitnessIsUnderDevicesOnlyWhereEverydayIsNotOnTheHub() {
        XCTAssertFalse(ids(SettingsSearchConditions()).contains("health-fitness-devices"))
        let simple = ids(SettingsSearchConditions(simpleMode: true))
        XCTAssertTrue(simple.contains("health-fitness-devices"))
        XCTAssertFalse(simple.contains("health-summaries"), "Everyday's own rows go with Everyday")
    }

    // MARK: - Ids

    /// Pins store these. A changed id loses someone's pin, so the whole list is written down.
    static let pinnedIDs: [String] = [
        "category-intelligence", "ai-models", "realtime-models", "end-quiet-session", "personas",
        "system-prompt", "keep-talking-without-signal", "smart-routing", "auto-model-routing",
        "model-fallback", "stuck-reply", "narrate-model-switches", "vision-images", "agentic-features",
        "let-agents-see", "run-on-device-model", "look-up-tools", "category-voice", "assistant-name",
        "listen-for-wake-phrase", "wake-phrase", "push-to-talk", "siri-questions", "quiet-after-actions",
        "connecting-cue", "pause-before-answering", "interrupt-when-you-speak", "one-question-at-a-time",
        "check-before-sending", "ignore-nearby-chatter", "hands-free-triggers", "temple-taps",
        "category-everyday", "user-memory", "what-avenkin-remembers", "conversation-history",
        "remember-earlier", "conversation-notes", "memory-suggestions", "goals", "activity",
        "memory-enrichment", "my-day", "my-day-on-home", "my-day-contents", "ready-to-send-cards",
        "scheduled-delivery", "scheduled-tasks", "walking-navigation", "parking", "smart-home-control",
        "ai-messaging", "music-podcasts", "home-assistant", "translation", "health", "ai-health-vault",
        "health-summaries", "first-aid", "share-health", "private-conversations", "category-my-manuals",
        "category-devices", "glasses", "wake-listen-mic", "reply-audio", "sleep-when-quiet",
        "update-glasses-app", "update-glasses-firmware", "instant-replay", "display-backend",
        "apple-watch", "smart-ring", "hardware-privacy", "microphone", "audio-only-mode", "dwell-capture",
        "phone-mic-translation", "glasses-only-audio", "voice-isolation", "blur-bystander-faces",
        "encrypt-conversations", "keep-history-for", "insights", "teleprompter-phone",
        "health-fitness-devices", "medical-compliance", "cloud-ai-sharing", "requests-processed",
        "category-accessibility", "reading-accessibility", "scene-narration", "blind-assistant-on-open",
        "readiness-check", "requests-processed-accessibility", "spoken-cues", "scan-assist",
        "fingerspelling", "category-field-assist", "enable-field-assist", "workiz", "stock-system",
        "default-vault", "reference-files", "manual-search", "field-sync", "default-session-mode",
        "time-billing", "experts", "expert-stream-transport", "category-assisting",
        "category-look-and-feel", "theme", "accent-colour", "languages", "category-tools", "quick-actions",
        "tools", "offline-mode", "custom-vaults", "personal-notes", "study-mode", "reading",
        "health-vault", "custom-tools", "skill-packs", "add-ons", "siri-search", "mcp-server", "playbooks",
        "skill-store", "voice-skills", "suggested-skills", "category-connections", "works-with-iphone",
        "weather-data", "services", "gateways", "mcp-servers", "category-capture", "recordings",
        "meeting-records", "caption-sessions", "camera-recording-streaming", "category-display",
        "glasses-display-hud", "hud-choice-buttons", "lens-keeps-phone-mic", "display-busy-hint",
        "follow-ups-on-display", "answers-on-lens", "highlight-colour", "practise-band", "fit-check",
        "hud-mirror", "teleprompter", "category-advanced", "developer", "prompt-inspector",
        "network-activity", "live-vision", "documents", "capture-flow", "category-diagnostics",
        "simple-mode", "lock-settings", "support-email", "send-todays-activity", "run-diagnostics",
        "report-a-problem", "export-diagnostics", "delete-ai-turn-records",
    ]

    func testIdsAreStableUniqueAndKebabCase() {
        let ids = SettingsIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "an id is used twice")
        XCTAssertEqual(ids, Self.pinnedIDs, "an id changed, moved or was added: pins store these")
        for id in ids {
            XCTAssertNotNil(id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression), id)
        }
        XCTAssertEqual(SettingsIndex.ids, Set(ids))
    }

    func testEveryEntryHasWordsAndNoEmptyKeyword() {
        for entry in SettingsIndex.entries {
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespaces).isEmpty, entry.id)
            for keyword in entry.keywords { XCTAssertFalse(keyword.isEmpty, entry.id) }
            XCTAssertEqual(entry.title, entry.title.trimmingCharacters(in: .whitespaces), entry.id)
        }
    }

    func testEveryDestinationHasAScreenEntry() {
        let screens = SettingsIndex.entries.filter { $0.kind == .screen }.map(\.destination)
        for id in SettingsCategoryID.allCases {
            XCTAssertTrue(screens.contains(.category(id)), id.rawValue)
        }
        for id in SettingsScreenID.allCases {
            XCTAssertTrue(screens.contains(.screen(id)), id.rawValue)
            XCTAssertFalse(SettingsIndex.title(of: id).isEmpty, id.rawValue)
        }
        // Every setting opens a screen someone can name.
        for entry in SettingsIndex.entries where entry.kind == .setting {
            XCTAssertTrue(screens.contains(entry.destination), entry.id)
        }
    }

    // MARK: - Where it lives

    func testBreadcrumbsNameTheHubRowThenTheScreens() throws {
        let glasses = SettingsHubPhone(glassesSupported: true)
        func crumb(_ id: String) throws -> String {
            SettingsIndex.breadcrumb(for: try XCTUnwrap(SettingsIndex.entry(id)), on: glasses)
        }
        XCTAssertEqual(try crumb("category-voice"), "Assistant")
        XCTAssertEqual(try crumb("wake-phrase"), "Assistant › Voice & Triggers")
        XCTAssertEqual(try crumb("category-accessibility"), "Settings")
        XCTAssertEqual(try crumb("hardware-privacy"), "Devices & Privacy")
        XCTAssertEqual(try crumb("microphone"), "Devices & Privacy › Hardware & Privacy")
        XCTAssertEqual(try crumb("insights"), "Devices & Privacy › Hardware & Privacy")
        XCTAssertEqual(try crumb("display-backend"), "Devices & Privacy › Glasses")
        XCTAssertEqual(try crumb("glasses-display-hud"), "Devices & Privacy › Glasses › Display & HUD")
        XCTAssertEqual(try crumb("weather-data"), "Connections › Works with your iPhone")
        XCTAssertEqual(try crumb("auto-model-routing"), "Assistant › Smart Routing")
    }

    // MARK: - The index stays complete

    /// Screens the inventory names that need no entry of their own, and why.
    static let inventoryExemptions: [String: String] = [
        "SettingsCategoryScreen": "The Display & HUD link on the Glasses page: the Display & HUD category's own entry opens it.",
    ]

    func testEveryScreenTheHubReachesHasAnEntry() throws {
        let built = Set(try Self.destinationTypes().values)
        let categoryScreens = Set(SettingsIndex.entries.filter { $0.kind == .screen }.compactMap { entry -> SettingsCategoryID? in
            if case .category(let id) = entry.destination { return id }
            return nil
        })
        for item in SettingsHubTests.inventory {
            if Self.inventoryExemptions[item.screen] != nil { continue }
            if item.via.isEmpty {
                XCTAssertTrue(categoryScreens.contains(item.category), "\(item.screen): no entry for its category")
            } else {
                XCTAssertTrue(built.contains(item.screen),
                              "\(item.screen) has no index entry — add one to SettingsIndex, or an exemption here")
            }
        }
    }

    func testEverySwitchTheEverydayGroupsDrawHasAnEntry() {
        let titles = Set(SettingsIndex.entries.map(\.title))
        for member in SettingsGroupCatalog.all.flatMap(\.members) {
            XCTAssertTrue(titles.contains(member.title), "\(member.title) has no index entry")
            let gated = SettingsIndex.entries.filter { $0.gate.contains(.groupMember(member.id)) }
            XCTAssertFalse(gated.isEmpty, "\(member.id): no entry follows its presentation")
        }
    }

    /// InfoToggle titles that need no entry of their own, and why.
    static let infoToggleExemptions: [String: String] = [
        "Temple Taps (Experimental)": "The Temple Taps screen's own switch: the Temple Taps entry opens it.",
        "trigger.displayName": "One row per hands-free trigger: the Hands-Free Triggers entry covers them.",
        "Self.title": "OfflineHandoffSettingsRow.title, indexed as keep-talking-without-signal (asserted below).",
    ]

    func testEveryInfoToggleTitleHasAnEntry() throws {
        let titles = Set(SettingsIndex.entries.map(\.title))
        var found = 0
        for (file, source) in Self.viewSources {
            var rest = source[...]
            while let start = rest.range(of: "InfoToggle(") {
                rest = rest[start.upperBound...]
                guard !source[..<start.lowerBound].hasSuffix("struct ") else { continue }
                let title = try XCTUnwrap(Self.titleLiteral(in: String(rest.prefix(400))),
                                          "\(file): an InfoToggle with no title")
                found += 1
                if Self.infoToggleExemptions[title] != nil { continue }
                XCTAssertTrue(titles.contains(title), "\(file): \"\(title)\" has no index entry")
            }
        }
        XCTAssertGreaterThan(found, 35, "the scan found too few InfoToggles to trust")
        XCTAssertEqual(SettingsIndex.entry("keep-talking-without-signal")?.title, OfflineHandoffSettingsRow.title)
    }

    /// `title: "…"`, `title: String(localized: "…")`, or the expression for a runtime title.
    private static func titleLiteral(in call: String) -> String? {
        guard let label = call.range(of: "title:") else { return nil }
        let after = call[label.upperBound...].drop { $0 == " " || $0 == "\n" }
        let literal: Substring
        if after.hasPrefix("\"") {
            literal = after.dropFirst()
        } else if after.hasPrefix("String(localized: \"") {
            literal = after.dropFirst("String(localized: \"".count)
        } else {
            return String(after.prefix { $0 != "," && $0 != "\n" })
        }
        var text = ""
        var escaped = false
        for character in literal {
            if escaped { text.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { break }
            text.append(character)
        }
        return text
    }

    // MARK: - What a result opens

    /// Each screen is built as the screen that links to it builds it.
    static let expectedTypes: [SettingsScreenID: String] = [
        .realtimeModels: "RealtimeModelsView", .personas: "PersonasView", .systemPrompt: "PromptPresetsView",
        .smartRouting: "SmartRoutingView", .visionImages: "LLMImageSettingsView",
        .agenticFeatures: "AgenticFeaturesView", .templeTaps: "TempleTapSettingsView", .memory: "MemoryView",
        .goals: "GoalsView", .activity: "ActivityView", .myDayContents: "MyDayContentsSettingsView",
        .preparedCards: "PreparedCardSettingsView", .myDayDelivery: "MyDayDeliverySettingsView",
        .scheduledTasks: "ScheduledTasksView", .navigation: "NavigationSettingsView",
        .parking: "ParkingSettingsView", .music: "MusicSettingsView", .homeAssistant: "HomeAssistantSettingsView",
        .translation: "TranslationSettingsView", .health: "HealthSettingsView", .glasses: "GlassesSettingsView",
        .displayBackend: "EvenDisplaySettingsView", .appleWatch: "AppleWatchSettingsView",
        .smartRing: "RingSettingsView", .hardwarePrivacy: "HardwarePrivacyView", .insights: "InsightsView",
        .teleprompterOnPhone: "TeleprompterSettingsView", .healthFitness: "EverydaySettingsScreen",
        .medicalCompliance: "MedicalCompliancePaywallView", .cloudAISharing: "CloudProcessingSettingsView",
        .processingSummary: "ProcessingSummaryView", .readinessCheck: "ReadinessWalkthroughView",
        .scanAssist: "ScanAssistSettingsView", .fingerspelling: "FingerspellingSettingsView",
        .languages: "LanguageSettingsView", .quickActions: "QuickActionsSettingsView", .tools: "ToolsSettingsView",
        .customVaults: "VaultManagerView", .personalNotes: "VaultFilesEditorView", .studyMode: "DeckListView",
        .reading: "ReadingStatsView", .healthVault: "HealthVaultEditorView", .customTools: "CustomToolsView",
        .skillPacks: "SkillPacksSettingsView", .addOns: "AddOnsSettingsView", .siriSearch: "SiriExposureView",
        .mcpServer: "MCPServerSettingsView", .playbooks: "PlaybooksSettingsView", .skillStore: "ClawHubBrowserView",
        .voiceSkills: "VoiceSkillsManagerView", .suggestedSkills: "SuggestedSkillsView",
        .appleIntegrations: "AppleIntegrationsSettingsScreen", .weatherData: "WeatherDataAboutView",
        .services: "ServicesSettingsView", .gateways: "GatewaySettingsView", .mcpServers: "MCPServersView",
        .recordings: "RecordingsView", .meetingRecords: "MeetingRecordsView", .captionSessions: "CaptionSessionsView",
        .bandPractice: "BandPracticeView", .lensFitCheck: "LensFitCheckView", .hudMirror: "HUDMirrorView",
        .teleprompter: "TeleprompterSettingsView", .developer: "DeveloperPanelView",
        .promptInspector: "PromptInspectorView", .networkActivity: "NetworkMonitorView",
        .liveVision: "LiveVisionSettingsView", .documents: "DocumentsView", .captureFlow: "CaptureFlowAuthorView",
        .diagnosticExport: "DiagnosticExportView",
    ]

    func testTheDestinationScreenBuildsEachScreensOwnType() throws {
        XCTAssertEqual(Set(Self.expectedTypes.keys), Set(SettingsScreenID.allCases))
        XCTAssertEqual(try Self.destinationTypes(), Self.expectedTypes)
        let source = try XCTUnwrap(Self.viewSources.first { $0.file == "SettingsSearchViews.swift" }?.text)
        // A category goes through its lock wrapper, and a hidden entry draws the hidden screen.
        XCTAssertTrue(source.contains("SettingsCategoryScreen(appState: appState, id: id)"))
        XCTAssertTrue(source.contains("SettingsIndex.opens(entry.destination, in: .current(simpleMode: simpleModeEnabled))"))
        XCTAssertTrue(source.contains("ManagedHiddenScreen(organization: ManagedLockReason.organization)"))
    }

    /// The hub keeps the expressions `SettingsHubTests` reads, and opens results through the screen above.
    func testTheHubOpensResultsThroughTheDestinationScreen() throws {
        let hub = try XCTUnwrap(Self.viewSources.first { $0.file == "SettingsView.swift" }?.text)
        XCTAssertTrue(hub.contains("SettingsIndexDestinationScreen(appState: appState, entry: entry)"))
        XCTAssertTrue(hub.contains("SettingsSearchField(query: $searchQuery, isActive: !settingsLocked)"))
        XCTAssertTrue(hub.contains("if !settingsLocked {\n                SettingsPinnedSection("))
    }

    /// `case .x:` in `SettingsIndexDestinationScreen.screen(_:)` → the type its `AnyView(` wraps.
    static func destinationTypes() throws -> [SettingsScreenID: String] {
        let source = try XCTUnwrap(viewSources.first { $0.file == "SettingsSearchViews.swift" }?.text)
        let start = try XCTUnwrap(source.range(of: "private func screen(_ id: SettingsScreenID) -> AnyView {"))
        let end = try XCTUnwrap(source.range(of: "/// A glasses screen on the phone-only build"))
        let body = source[start.upperBound..<end.lowerBound]
        var result: [SettingsScreenID: String] = [:]
        for block in body.components(separatedBy: "\n        case .").dropFirst() {
            let name = String(block.prefix { $0 != ":" })
            let id = try XCTUnwrap(SettingsScreenID.allCases.first { "\($0)" == name }, "unknown case \(name)")
            let wrapped = try XCTUnwrap(block.range(of: "AnyView("), "\(name) builds no screen")
            result[id] = String(block[wrapped.upperBound...].prefix { $0.isLetter || $0.isNumber })
        }
        return result
    }

    static let viewSources: [(file: String, text: String)] = {
        let root = SettingsHubTests.repoRoot.appendingPathComponent("OpenGlasses/Sources/App/Views")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
        }
    }()
}

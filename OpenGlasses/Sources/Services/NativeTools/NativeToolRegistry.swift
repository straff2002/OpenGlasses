import Foundation

/// Holds all registered native tools and provides lookup by name.
@MainActor
final class NativeToolRegistry {
    private var tools: [String: any NativeTool] = [:]
    private var fieldToolNames: Set<String> = []
    private var registeringFieldTools = false
    let myDayService: MyDayService
    /// Where `lookup_tools` finds the MCP client, whose offered tools it may also describe (Plan
    /// IU). Set by `NativeToolRouter.init`, which owns the client; nil leaves the lookup native-only.
    var mcpClientSource: (@MainActor () -> MCPClient?)?

    init(locationService: LocationService, conversationStore: ConversationStore? = nil,
         cameraService: CameraService? = nil,
         memoryRewindService: MemoryRewindService? = nil,
         ambientCaptionService: AmbientCaptionService? = nil,
         openClawBridge: OpenClawBridge? = nil,
         videoRecorder: VideoRecordingService? = nil,
         audioRecorder: AudioRecordingService? = nil,
         medicalExportService: MedicalExportService? = nil,
         semanticMemory: SemanticMemoryStore? = nil,
         documentStore: DocumentStore? = nil,
         activeNamespace: (() -> String)? = nil,
         eventKitStore: EventKitDayStore? = nil,
         travelTimeSource: (any TravelTimeDaySource)? = nil,
         guidedJobFlow: GuidedJobFlow? = nil) {
        let eventKitStore = eventKitStore ?? EventKitDayStore()
        // Apple requires its Weather attribution wherever WeatherKit data is displayed; a weather
        // answer lands in the active chat thread, so the thread is recorded to carry the credit.
        let weatherTool = WeatherTool(locationService: locationService) { [weak conversationStore] in
            WeatherAttributionThreads.shared.record(conversationStore?.activeThreadId)
        }
        let travelTimeSource = travelTimeSource
            ?? MapKitTravelTimeDaySource(locationService: locationService)
        let newsTool = NewsTool()
        let dateTimeTool = DateTimeTool()
        let myDayService = MyDayService(
            calendarSource: eventKitStore,
            remindersSource: eventKitStore,
            weatherSource: NativeWeatherDaySource(weatherTool: weatherTool),
            travelSource: travelTimeSource
        )
        self.myDayService = myDayService

        register(weatherTool)
        register(dateTimeTool)
        register(CalculatorTool())
        register(NewTopicTool())
        // Plan FF P1/PR8: "how are my requests processed", answered out loud. Registered
        // unconditionally — the answer is always true of the current settings, and a
        // privacy question that is only reachable on a screen is not reachable at all for
        // the wearer this exists for.
        register(ProcessingSummaryTool())
        // Scan Assist (Plan FB): deterministic start/pause/resume/stop and side control for
        // the accessibility reminder session. Registered unconditionally — the feature is off
        // by default and the tool reports that honestly rather than being invisible.
        register(ScanAssistTool())
        register(UnitConversionTool())
        register(TimerTool())
        register(SaveNoteTool())
        register(ListNotesTool())
        register(WebSearchTool())
        register(newsTool)
        register(TranslationTool())
        register(TranslateSignMenuTool())
        register(AskLocalPhraseTool(locationService: locationService))
        register(WhereAmITool(locationService: locationService))
        register(OpenAppTool())
        register(DirectionsTool())
        register(ShazamTool())
        register(CurrencyTool())
        register(MusicControlTool())
        register(PodcastTool())   // Plan JF: a podcast by name, opened in Apple Podcasts
        register(DailyBriefingTool(myDayService: myDayService))
        register(ClipboardTool())
        register(PhoneCallTool())
        register(FlashlightTool())
        #if !AVENKIN_PHONE_ONLY
        register(PinFrameTool())   // Plan CE: "pin this" — resolves AppState at execution time
        #endif
        register(NavigateTool())   // Plan CA: walking directions — resolves AppState at execution time
        register(ParkingTool(locationService: locationService))   // Plan GH: where did I park
        register(DeviceInfoTool())
        register(PomodoroTool())
        register(LocationSearchTool(locationService: locationService))
        register(WordDefinitionTool())
        register(SendMessageTool())
        register(SaveLocationTool(locationService: locationService))
        register(ListSavedLocationsTool(locationService: locationService))
        register(PedometerTool())
        // Plan GI: heart rate, sleep and steps from Apple Health. Read-only; speaks the answer
        // itself when the wearer has not allowed Health data to reach the model.
        register(HealthSummaryTool())
        register(EmergencyInfoTool(locationService: locationService))
        register(CalendarTool(eventStore: eventKitStore))
        register(ContactsTool())
        register(AppleRemindersTool(eventStore: eventKitStore))
        register(AlarmTool())
        register(BrightnessTool())
        register(HomeKitTool())
        register(SiriShortcutsTool())
        register(QuickActionTool())
        // Plan IW P1: the wearer's goals, and "what have you done / what's next". Both work without
        // Agent Mode and without signal; only a goal step's scheduled check needs Agent Mode.
        register(GoalsTool())
        register(ActivityTool())
        if let store = conversationStore {
            register(ConversationSummaryTool(conversationStore: store))
            register(SessionSearchTool(conversationStore: store))
        }
        if let rewind = memoryRewindService {
            register(MemoryRewindTool(rewindService: rewind))
        }
        // instant_replay: keep a moment the glasses camera already showed, from the rolling
        // buffer on the blurred relay. Glasses only: the buffer rides a glasses stream.
        #if !AVENKIN_PHONE_ONLY
        register(InstantReplayTool())
        #endif

        // Tier 2 tools
        register(GeofenceTool(locationService: locationService))
        register(MultiChannelMessageTool())
        if let captions = ambientCaptionService {
            register(MeetingSummaryTool(captionService: captions))
        }

        // Tier 3 tools
        var fitnessTool = FitnessCoachingTool()
        if let camera = cameraService {
            // BK P6: feed check_form the latest camera frame so it actually runs PoseAnalyzer,
            // making the tool's "check form via camera" claim true.
            fitnessTool.frameProvider = { camera.latestFrame }
        }
        register(fitnessTool)
        register(FirstAidTool())
        // BK P0: register the gateway-skills tool only when the gateway is an active agentic
        // capability (configured AND Agent Mode on). Registering on `isOpenClawConfigured` alone
        // would list `openclaw_skills` in the generated tool prompt/schema while Agent Mode is off
        // — a capability the model can't actually use (a P6-style honesty violation).
        if let bridge = openClawBridge, Config.isOpenClawAgentActive {
            var skillsTool = OpenClawSkillsTool()
            skillsTool.openClawBridge = bridge
            register(skillsTool)
        }

        // Tier 4: Voice skills, spatial memory, social context, contextual notes, Home Assistant
        register(VoiceSkillsTool())
        register(ObjectMemoryTool(locationService: locationService))
        register(ContextualNoteTool(locationService: locationService))
        register(SocialContextTool())
        // Always register — tool checks config at execution time
        register(HomeAssistantTool())
        register(VehicleTool())

        // Tier 5: Barcode scanning, live translation, food analysis, capture photo, QR context
        if let camera = cameraService {
            register(BarcodeScannerTool(cameraService: camera))
            register(DocumentScanTool(cameraService: camera))
            // The job sink is the shared session service, which is where `photo_log` already
            // files. Handed in rather than reached for, so the tool stays testable headless.
            register(CapturePhotoTool(cameraService: camera,
                                      jobEvidence: FieldSessionService.shared))
            register(QRContextTool(cameraService: camera))
            register(SmartCaptureTool(cameraService: camera))
            if let memory = semanticMemory {
                register(RememberSceneTool(cameraService: camera, memoryStore: memory))
            }
            // Plan CB: sharp-frame injection for live sessions. The injector resolves through
            // AppStateProvider at execution time — the session managers are per-session objects,
            // and capturing one here would go stale on the first teardown (see LookCloselyTool).
            //
            // Plan FF P1/PR4: the capture goes through the still chokepoint under
            // `PrivacyFilterScope.liveSession`, not `camera.capturePhoto()`. The unfiltered
            // accessor is the wearer's own framed shot; these pixels are pushed into a cloud
            // realtime session, which is an egress like the streamed frames beside them.
            let sharpStill = SharpStillCapture(provider: camera,
                                               cameraSession: { camera.readinessNow.session })
            register(LookCloselyTool(
                captureSharpStill: { identity in
                    await sharpStill.capture(liveSessionIdentity: identity)
                },
                injectorProvider: { AppStateProvider.shared?.activeLiveInjector },
                cameraSession: { camera.readinessNow.session },
                // Plan FF P0/PR2: the requested-capture cue, resolved at execution time for the
                // same reason the injector is — the coordinator belongs to an AppState this
                // process-lifetime tool must not capture.
                onCaptureSucceeded: { AppStateProvider.shared?.noteRequestedCaptureSucceeded() }))
            register(VisionAssessTool())   // structured vision (read the instrument, etc.) via StructuredVisionService.shared
            // Plan CG: badge OCR → person record in the brain store.
            register(BadgeScanTool(cameraService: camera, locationService: locationService))
            #if !AVENKIN_PHONE_ONLY
            if let recorder = videoRecorder {
                register(VideoRecordingTool(cameraService: camera, videoRecorder: recorder,
                                            medicalExportService: medicalExportService))
            }
            #endif
        }

        // Audio-only recording (lighter than video — no camera needed)
        if let recorder = audioRecorder {
            register(AudioRecordingTool(audioRecorder: recorder))
        }

        // Medical export tool
        if let exportService = medicalExportService {
            register(MedicalExportTool(exportService: exportService, videoRecorder: videoRecorder))
        }

        // Tier 6: Golf mode
        register(GolfModeTool(locationService: locationService))
        register(FoodAnalysisTool())
        register(AgentScheduleTool())
        register(AgentDocumentTool())
        register(PlaybookTool())
        // Remote Agent Harness (Plan N): voice control of a remote coding agent. Always registered;
        // the tool self-gates on Config.agentModeEnabled at execute time.
        register(AgentControlTool())

        // Personal/manual tools recheck the resolved source at execution. Keeping their schemas
        // registered also lets an empty library explain how to add a manual after a purchase.
        PersonalManualLibrary.shared.documents = documentStore
        register(ManualLookupTool(documentStore: documentStore, cameraService: cameraService))
        register(ManualFigureTool(documentStore: documentStore))
        register(ShowSourceTool(documentStore: documentStore))
        register(TableLookupTool(documentStore: documentStore))
        register(ManualCaptureTool())

        // Construct the professional tools once, but expose them only through the live capability
        // and mode gate. A StoreKit upgrade/downgrade must take effect without restarting the app.
        do {
            registeringFieldTools = true
            defer { registeringFieldTools = false }
            register(FieldSessionTool(flow: guidedJobFlow))
            register(ProjectNoteTool())
            register(ProcedureRunnerTool())
            register(CaptureFlowTool())
            // A spoken superheat or subcool is checked and recorded like a photographed one.
            register(DomainCalcTool(recorder: FieldSessionService.shared))
            register(EscalateToExpertTool())
            register(NetworkCalcTool())
            // equipment_lookup gains an on-device OCR path when a camera is present.
            register(EquipmentLookupTool(cameraService: cameraService, documentStore: documentStore,
                                        flow: guidedJobFlow))
            // manual_lookup searches the vault's imported OEM manuals (reference tier, Plan ED).
            // The work record (Plan EM): a recommendation is an object the technician decides on,
            // and a part number is only written down once it has been looked up.
            register(ProposeTaskTool())
            register(TaskTool())
            // Readings and evidence choices said out loud (Plan GB P3).
            register(ReadingTool())
            register(EvidenceTool())
            register(PartsRequestTool())
            // What the office's records say was done on a unit before (Plan HU P2): read from
            // the job file the office sent, offline, never fetched.
            register(ServiceHistoryTool(flow: guidedJobFlow))
            // The technician's own van stock (Plan IH): loaded at the shop with no job open, so
            // it needs Field Assist and nothing else.
            register(VanStockTool())
            // "Note this for the team" (Plan FP P1): a finding filed for a supervisor's review. The
            // tool checks Field Assist; the team-learning capability is checked by its service.
            register(TeamLearningTool())
            // deliver_report stages the finished record for the composer; iOS makes the technician
            // tap Send, which is the human-in-the-loop step rather than an obstacle.
            register(DeliverReportTool(thread: { [weak conversationStore] in
                // The conversation the request came in, so a report asked for just after a close
                // goes to that job and not to one from another chat (Plan GB P0).
                guard let store = conversationStore, let id = store.activeThreadId else { return .none }
                return .init(id: id, createdAt: store.threads.first { $0.id == id }?.createdAt)
            }))
            // manual_figure puts a numbered drawing on the phone and in the next turn's image slot.
            // show_source opens the page the last answer cited, its passage highlighted (Plan IN P2).
            // table_lookup reads one cell of a table extracted from the vault's own manuals, with
            // its headers, notes and page (Plan JJ P1).
            // rule_chain runs a chain the vault's chains.md offers — asks, table lookups,
            // arithmetic, a check — one step at a time, read back with a citation per step (Plan JJ
            // P2).
            register(RuleChainTool(documentStore: documentStore))
            // propose_chain checks a chain the model proposes from the passages it retrieved, for a
            // question no authored chain answers, and holds it for the technician's go (Plan JJ P3).
            register(ProposeChainTool(documentStore: documentStore))
            // Safety Assessment (HECA) — camera high-energy hazard assessment via SafetyAssessmentService.shared.
            register(SafetyAssessmentTool())
            if let camera = cameraService {
                register(PhotoLogTool(cameraService: camera, jobEvidence: FieldSessionService.shared))
                // refrigerant_gauges: superheat and subcooling from one photo of the gauges (Plan IS
                // P1), filed on the job beside photo_log's photos.
                register(RefrigerantGaugeTool(cameraService: camera, recorder: FieldSessionService.shared))
            }
            // record_clip: the sibling of photo_log for a fault a still cannot show (Plan FO P2b).
            // It needs no camera reference of its own — it records off the blurred frame relay,
            // which only `AppState` is allowed to hand out.
            #if !AVENKIN_PHONE_ONLY
            register(RecordClipTool())
            #endif
        }

        // Accessibility Tier (A1) — Reading Accessibility. Needs the camera for OCR.
        if Config.accessibilityModeEnabled, let camera = cameraService {
            register(ReadingAccessibilityTool(cameraService: camera))
            // Low-Vision Navigation Assist (Plan J) — deps configured by AppState.
            #if !AVENKIN_PHONE_ONLY
            register(NavigationAssistTool())
            #endif
            // Sight tools: name colors / identify banknotes.
            register(ColorIdentifierTool(cameraService: camera))
            register(MoneyIdentifierTool(cameraService: camera))
        }

        // Personal Health Vault (Plan B) — always registered; the tool checks the Medical
        // Compliance unlock at execution time.
        register(HealthVaultTool())
        // Personal Health-Safety Advisor (Plan AB) — "is this safe for me?" over the vault,
        // backstopped by a deterministic interaction rubric. Same Medical Compliance gate.
        register(HealthSafetyTool())
        // Personal Notes Vault — free second-brain over VaultStore.
        register(NotesVaultTool())
        // Medication Identifier (Plan I) — OCR a label, cross-check the Health Vault. Needs camera.
        if let camera = cameraService {
            register(MedicationIdentifierTool(cameraService: camera))
        }

        // Utilities (Plan D)
        register(AircraftOverheadTool(locationService: locationService))

        // Live Coach (Plan C) — service deps are configured by AppState; tool just starts/stops.
        #if !AVENKIN_PHONE_ONLY
        register(LiveCoachTool())
        #endif
        // Always registered — tool checks agentModeEnabled at execution time
        register(YieldToHumanTool())
        var discoveryTool = DiscoverCapabilitiesTool()
        discoveryTool.toolRegistry = self
        register(discoveryTool)
        // Plan IU: full definitions on demand. Declared only when a turn's exposure is core, and
        // never listed as a tool of its own (`toolNames`, `ToolDeclarations.declarableNames`).
        var lookupTool = ToolLookupTool()
        lookupTool.toolRegistry = self
        register(lookupTool)
        register(ChineseAppsTool())
        register(AsianMessagingTool())

        // Unified brain — knowledge graph + cross-store retrieval ([[BrainTool]]).
        // Registered unconditionally: the graph and encounter log work even with
        // semantic memory disabled; the tool degrades gracefully per missing store.
        var brainTool = BrainTool()
        brainTool.memoryStore = semanticMemory
        brainTool.documentStore = documentStore
        brainTool.activeNamespace = activeNamespace   // Project scoping (Plan AN / BM P8)
        // An encounter the user logs without naming a place records where the phone is.
        brainTool.currentPlace = { [weak locationService] in
            guard let locationService else { return nil }
            let coordinate = locationService.currentLocation?.coordinate
            guard locationService.locationContext != nil || coordinate != nil else { return nil }
            return BrainTool.EncounterPlace(name: locationService.locationContext,
                                            latitude: coordinate?.latitude,
                                            longitude: coordinate?.longitude)
        }
        register(brainTool)

        // Semantic memory tools — only available when memory is enabled
        if let memory = semanticMemory {
            var searchTool = MemorySearchTool()
            searchTool.memoryStore = memory
            searchTool.activeNamespace = activeNamespace   // Project scoping (Plan AN / BM P8)
            register(searchTool)
            var diaryTool = AgentDiaryTool()
            diaryTool.memoryStore = memory
            register(diaryTool)
        }

        // Document RAG — on-device knowledge base ([[DocumentRAGTool]])
        if let docStore = documentStore {
            var ragTool = DocumentRAGTool()
            ragTool.documentStore = docStore
            ragTool.cameraService = cameraService
            ragTool.activeNamespace = activeNamespace   // Project scoping (Plan AN)
            register(ragTool)
            // Study Mode — flashcards + quizzes over the same documents (via StudyService.shared).
            register(StudyTool())
        }
        // Reading companion — session lifecycle only; the book Q&A rides the context block
        // ReadingCompanionService injects into the prompt (Plan BT).
        #if !AVENKIN_PHONE_ONLY
        register(ReadingSessionTool())
        #endif

        // LiveTranslationTool is registered separately after the service is created

        // User-defined custom tools
        registerCustomTools()
    }

    /// Register (or re-register) all user-defined custom tools from Config.
    func registerCustomTools() {
        for definition in Config.customTools {
            let wrapper = CustomToolWrapper(definition: definition)
            tools[wrapper.name] = wrapper
        }
    }

    func register(_ tool: any NativeTool) {
        tools[tool.name] = tool
        if registeringFieldTools { fieldToolNames.insert(tool.name) }
    }

    /// Remove every registered skill-pack wrapper (Plan BX). The store's merge calls this first,
    /// so uninstall/disable is a rebuild rather than a leak: packs removed from the store stop
    /// existing in the registry the next time the merge runs.
    func removeSkillPackTools() {
        for (name, tool) in tools where tool is SkillPackToolWrapper {
            tools.removeValue(forKey: name)
        }
    }

    func tool(named name: String) -> (any NativeTool)? {
        guard !fieldToolNames.contains(name) || Config.fieldAssistActive else { return nil }
        guard Config.isToolEnabled(name) else { return nil }
        // HIPAA mode disables tools that could leak PHI
        if Config.hipaaMode, Config.hipaaDisabledTools.contains(name) { return nil }
        return tools[name]
    }

    /// All registered tools (including disabled) — for the Tools settings UI.
    var allTools: [any NativeTool] {
        Array(tools.values)
    }

    /// Only enabled tool names — used for system prompt injection.
    /// HIPAA mode automatically excludes tools that could leak PHI.
    var toolNames: [String] {
        Array(tools.keys).filter { name in
            guard !fieldToolNames.contains(name) || Config.fieldAssistActive else { return false }
            // Plan IU: infrastructure for on-demand definitions, not a tool the prompt lists.
            guard name != ToolLookupTool.toolName else { return false }
            guard Config.isToolEnabled(name) else { return false }
            if Config.hipaaMode, Config.hipaaDisabledTools.contains(name) { return false }
            return true
        }.sorted()
    }

    /// Enabled (name, description) pairs for the given names, in the order provided — the single
    /// source for the system-prompt tool list (Plan BG P1). Skips any name the registry doesn't
    /// own so callers can pass a pre-filtered `toolNames` slice safely.
    func toolDescriptions(for names: [String]) -> [(name: String, description: String)] {
        names.compactMap { name in
            guard !fieldToolNames.contains(name) || Config.fieldAssistActive else { return nil }
            guard let tool = tools[name] else { return nil }
            return (name, tool.description)
        }
    }

    /// Context-aware tool names — filters out tools that aren't relevant to the current state.
    /// Reduces token usage by only including tools the LLM can actually use right now.
    func contextualToolNames(
        glassesConnected: Bool,
        homeAssistantConfigured: Bool,
        openClawConfigured: Bool,
        hasActiveWorkout: Bool = false
    ) -> [String] {
        let allEnabled = toolNames

        return allEnabled.filter { name in
            // Camera-dependent tools: only include when glasses are connected
            let cameraTools: Set = ["scan_code", "scan_document", "capture_photo", "qr_context", "video_recording"]
            if cameraTools.contains(name) && !glassesConnected { return false }

            // Home tools: only include when configured
            let homeTools: Set = ["smart_home", "home_assistant"]
            if homeTools.contains(name) && !homeAssistantConfigured { return false }

            // OpenClaw: only include when configured
            if name == "openclaw_skills" && !openClawConfigured { return false }

            // Meeting summary needs ambient captions running
            // (still include it — tool gives a helpful error message)

            return true
        }
    }

    // There is deliberately no `executeTool(name:arguments:)` here.
    //
    // A lookup-and-execute helper on the registry is how every bypass in this app started: a Siri
    // Action, a skill-pack binding, and an LLM-free fast path each reached one and ran an acting
    // tool without the confirmation gate, the safety supervisor, or the egress screen. Execution
    // belongs to `NativeToolRouter.execute(_:)` and to nothing else; this type resolves and lists
    // tools. New callers take a `ToolExecutionAuthority`, not a tool instance.
}

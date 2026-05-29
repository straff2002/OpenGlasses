import Foundation

/// Holds all registered native tools and provides lookup by name.
@MainActor
final class NativeToolRegistry {
    private var tools: [String: any NativeTool] = [:]

    init(locationService: LocationService, conversationStore: ConversationStore? = nil,
         faceRecognitionService: FaceRecognitionService? = nil, cameraService: CameraService? = nil,
         memoryRewindService: MemoryRewindService? = nil,
         ambientCaptionService: AmbientCaptionService? = nil,
         openClawBridge: OpenClawBridge? = nil,
         videoRecorder: VideoRecordingService? = nil,
         audioRecorder: AudioRecordingService? = nil,
         medicalExportService: MedicalExportService? = nil,
         semanticMemory: SemanticMemoryStore? = nil) {
        let weatherTool = WeatherTool(locationService: locationService)
        let newsTool = NewsTool()
        let dateTimeTool = DateTimeTool()

        register(weatherTool)
        register(dateTimeTool)
        register(CalculatorTool())
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
        register(DailyBriefingTool(weatherTool: weatherTool, newsTool: newsTool, dateTimeTool: dateTimeTool))
        register(ClipboardTool())
        register(PhoneCallTool())
        register(FlashlightTool())
        register(DeviceInfoTool())
        register(PomodoroTool())
        register(LocationSearchTool(locationService: locationService))
        register(WordDefinitionTool())
        register(SendMessageTool())
        register(SaveLocationTool(locationService: locationService))
        register(ListSavedLocationsTool(locationService: locationService))
        register(PedometerTool())
        register(EmergencyInfoTool(locationService: locationService))
        register(CalendarTool())
        register(ContactsTool())
        register(AppleRemindersTool())
        register(AlarmTool())
        register(BrightnessTool())
        register(HomeKitTool())
        register(SiriShortcutsTool())
        register(QuickActionTool())
        if let store = conversationStore {
            register(ConversationSummaryTool(conversationStore: store))
            register(SessionSearchTool(conversationStore: store))
        }
        if let faceService = faceRecognitionService, let camera = cameraService {
            register(FaceRecognitionTool(faceService: faceService, cameraService: camera))
        }
        if let rewind = memoryRewindService {
            register(MemoryRewindTool(rewindService: rewind))
        }

        // Tier 2 tools
        register(GeofenceTool(locationService: locationService))
        register(MultiChannelMessageTool())
        if let captions = ambientCaptionService {
            register(MeetingSummaryTool(captionService: captions))
        }

        // Tier 3 tools
        register(FitnessCoachingTool())
        if let bridge = openClawBridge, Config.isOpenClawConfigured {
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

        // Tier 5: Barcode scanning, live translation, food analysis, capture photo, QR context
        if let camera = cameraService {
            register(BarcodeScannerTool(cameraService: camera))
            register(DocumentScanTool(cameraService: camera))
            register(CapturePhotoTool(cameraService: camera))
            register(QRContextTool(cameraService: camera))
            if let recorder = videoRecorder {
                register(VideoRecordingTool(cameraService: camera, videoRecorder: recorder,
                                            medicalExportService: medicalExportService))
            }
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

        // Field Assist (B2B) — only registered when the feature is enabled.
        // Tool checks Config.fieldAssistEnabled at execute time too, so users see a clear message.
        if Config.fieldAssistEnabled {
            register(FieldSessionTool())
            register(ProcedureRunnerTool())
            register(DomainCalcTool())
            register(EscalateToExpertTool())
            register(NetworkCalcTool())
            // equipment_lookup gains an on-device OCR path when a camera is present.
            register(EquipmentLookupTool(cameraService: cameraService))
            if let camera = cameraService {
                register(PhotoLogTool(cameraService: camera))
            }
        }

        // Accessibility Tier (A1) — Reading Accessibility. Needs the camera for OCR.
        if Config.accessibilityModeEnabled, let camera = cameraService {
            register(ReadingAccessibilityTool(cameraService: camera))
            // Low-Vision Navigation Assist (Plan J) — deps configured by AppState.
            register(NavigationAssistTool())
            // Sight tools: name colors / identify banknotes.
            register(ColorIdentifierTool(cameraService: camera))
            register(MoneyIdentifierTool(cameraService: camera))
        }

        // Personal Health Vault (Plan B) — always registered; the tool checks the Medical
        // Compliance unlock at execution time.
        register(HealthVaultTool())
        // Personal Notes Vault — free second-brain over VaultStore.
        register(NotesVaultTool())
        // Medication Identifier (Plan I) — OCR a label, cross-check the Health Vault. Needs camera.
        if let camera = cameraService {
            register(MedicationIdentifierTool(cameraService: camera))
        }

        // Utilities (Plan D)
        register(AircraftOverheadTool(locationService: locationService))

        // Live Coach (Plan C) — service deps are configured by AppState; tool just starts/stops.
        register(LiveCoachTool())
        // Always registered — tool checks agentModeEnabled at execution time
        register(YieldToHumanTool())
        var discoveryTool = DiscoverCapabilitiesTool()
        discoveryTool.toolRegistry = self
        register(discoveryTool)
        register(ChineseAppsTool())
        register(AsianMessagingTool())

        // Semantic memory tools — only available when memory is enabled
        if let memory = semanticMemory {
            var searchTool = MemorySearchTool()
            searchTool.memoryStore = memory
            register(searchTool)
            var diaryTool = AgentDiaryTool()
            diaryTool.memoryStore = memory
            register(diaryTool)
        }

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
    }

    func tool(named name: String) -> (any NativeTool)? {
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
            guard Config.isToolEnabled(name) else { return false }
            if Config.hipaaMode, Config.hipaaDisabledTools.contains(name) { return false }
            return true
        }.sorted()
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
            let cameraTools: Set = ["scan_code", "scan_document", "capture_photo", "face_recognition", "qr_context", "video_recording"]
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

    /// Execute a tool by name with the given arguments.
    /// Used by the ConversationClassifier for direct (LLM-free) tool calls.
    func executeTool(name: String, arguments: [String: Any]) async throws -> String {
        guard let tool = tool(named: name) else {
            throw NativeToolError.toolNotFound(name)
        }
        return try await tool.execute(args: arguments)
    }
}

enum NativeToolError: LocalizedError {
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name): return "Tool '\(name)' not found or disabled"
        }
    }
}

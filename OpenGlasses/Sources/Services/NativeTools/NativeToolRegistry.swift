import Foundation

/// Holds all registered native tools and provides lookup by name.
@MainActor
final class NativeToolRegistry {
    private var tools: [String: any NativeTool] = [:]

    init(locationService: LocationService, conversationStore: ConversationStore? = nil,
         faceRecognitionService: FaceRecognitionService? = nil, cameraService: CameraService? = nil,
         memoryRewindService: MemoryRewindService? = nil,
         ambientCaptionService: AmbientCaptionService? = nil,
         openClawBridge: OpenClawBridge? = nil) {
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
        if let store = conversationStore {
            register(ConversationSummaryTool(conversationStore: store))
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

        // Tier 5: Barcode scanning, live translation, food analysis
        if let camera = cameraService {
            register(BarcodeScannerTool(cameraService: camera))
        }
        register(FoodAnalysisTool())
        register(AgentScheduleTool())
        var discoveryTool = DiscoverCapabilitiesTool()
        discoveryTool.toolRegistry = self
        register(discoveryTool)
        register(ChineseAppsTool())
        register(AsianMessagingTool())
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
        return tools[name]
    }

    /// All registered tools (including disabled) — for the Tools settings UI.
    var allTools: [any NativeTool] {
        Array(tools.values)
    }

    /// Only enabled tool names — used for system prompt injection.
    var toolNames: [String] {
        Array(tools.keys).filter { Config.isToolEnabled($0) }.sorted()
    }
}

import Foundation

/// Reads the app into a `ScenarioContext` (Plan KH P1). The rules live in the pure types; this is
/// the only scenario file that knows where the answers are kept.
@MainActor
enum ScenarioEnvironment {

    /// A context for a running app.
    static func context(registry: NativeToolRegistry, isOnline: Bool,
                        captionHistoryExists: Bool) -> ScenarioContext {
        var context = base(isOnline: isOnline, captionHistoryExists: captionHistoryExists)
        context.fieldJobOpen = FieldToolProfile.fieldJobActive
        apply(tools: Set(registry.toolNames), to: &context)
        return context
    }

    /// A context for the Ready page. `AppState` is not safely usable before onboarding completes,
    /// so the tools are the catalogue's own, less what only exists with a mode on. Nothing is open,
    /// nothing has been captioned, and the phone is assumed online: the turn fails honestly if not.
    static func firstRunContext() -> ScenarioContext {
        var context = base(isOnline: true, captionHistoryExists: false)
        var tools = ScenarioCatalog.namedTools
        if !Config.accessibilityModeEnabled { tools.subtract(ToolExposureCore.accessibility) }
        tools.subtract(Config.disabledTools)
        if Config.hipaaMode { tools.subtract(Config.hipaaDisabledTools) }
        apply(tools: tools, to: &context)
        return context
    }

    private static func base(isOnline: Bool, captionHistoryExists: Bool) -> ScenarioContext {
        let model = Config.activeModel
        let onDevice = model.map { LLMService.isOnDeviceProvider($0.llmProvider) } ?? false
        var context = ScenarioContext()
        context.isOnline = isOnline
        context.captionHistoryExists = captionHistoryExists
        context.glassesAdded = Config.glassesAdded
        context.hipaaMode = Config.hipaaMode
        context.simpleMode = Config.simpleModeEnabled
        context.fieldAssistActive = Config.fieldAssistActive
        context.memoryOn = Config.userMemoryEnabled
        context.modelOnDevice = onDevice
        context.modelCanSee = !HomeGridPhotoPolicy.blocksPhoto(activeModel: model)
        let canAnswer = model.map {
            ScenarioToolOffer.modelCanAnswer(provider: $0.llmProvider, apiKey: $0.apiKey, baseURL: $0.baseURL,
                                             accountConnected: ClaudeOAuthService.shared.isConnected
                                                 || XAIOAuthService.shared.isConnected)
        } ?? false
        context.hasUsableModel = canAnswer
            && (isOnline || onDevice || OfflineHandoffAvailability.current().hasAnyModel)
        context.homeControlAvailable = !Config.homeAssistantURL.isEmpty || HomeKitTool.knownHomeCount > 0
        context.myManualsPermitted = PersonalManualLibrary.permitted
        context.myManualsHaveContent = PersonalManualLibrary.permitted
            && !PersonalManualLibrary.shared.manuals.isEmpty
        let shown = Set(SettingsVisibilityPolicy.hubCategories(
            simpleMode: Config.simpleModeEnabled, in: AdminGate.shared.settingsContext).map(\.id))
        context.unreachableSettings = Set(SettingsCategoryID.allCases).subtracting(shown)
        return context
    }

    private static func apply(tools: Set<String>, to context: inout ScenarioContext) {
        let closed = PolicyEnvelope.lockdown?.closedTools ?? []
        let featureOff = AIFeatureGate.disabledToolNames
        context.closedTools = closed
        context.toolsTurnedOff = Config.disabledTools.subtracting(closed)
        context.featureToolsOff = featureOff.subtracting(closed)
        context.availableTools = ScenarioToolOffer.offered(
            tools.subtracting(featureOff), provider: Config.activeModel?.llmProvider,
            fieldAssistActive: context.fieldAssistActive, isOnline: context.isOnline,
            libraryHasManuals: context.myManualsHaveContent)
    }
}

extension AppState {
    /// The cards the shelf would draw now, on the grid's rule for when a tile may run: Direct mode
    /// and no turn in progress. The shelf and the Voice tab's opening both ask this.
    func scenarioShelfCards(progress: ScenarioProgress) -> [ScenarioEntry] {
        guard HomeSurfaceVisibility.showsActionTiles(mode: currentMode), !isProcessing,
              !ScenarioShelfPolicy.hasEnded(progress) else { return [] }
        return ScenarioShelfPolicy.cards(
            from: ScenarioReadiness.visible(ScenarioCatalog.all, in: scenarioContext), progress: progress)
    }

    /// Where the scenarios stand on this phone now.
    var scenarioContext: ScenarioContext {
        ScenarioEnvironment.context(registry: nativeToolRegistry, isOnline: reachability.isOnline,
                                    captionHistoryExists: !ambientCaptions.captionHistory.isEmpty)
    }
}

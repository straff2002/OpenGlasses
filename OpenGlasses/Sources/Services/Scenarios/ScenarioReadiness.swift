import Foundation

/// What decides whether a scenario can run on this phone right now (Plan KH P1). Plain values, so
/// every row of the rules is a unit test. `ScenarioEnvironment` builds one from the app.
struct ScenarioContext: Equatable, Sendable {
    /// Tools a turn could reach now, after the person's and the organisation's lists, HIPAA, the
    /// mode gates and what the model in use is offered.
    var availableTools: Set<String> = []
    /// Tools the person switched off, one by one, in Tools.
    var toolsTurnedOff: Set<String> = []
    /// Tools off because the feature that owns them is off (`AIFeatureGate`).
    var featureToolsOff: Set<String> = []
    /// Tools an organisation closed. Never something the person can undo, so never a setup step.
    var closedTools: Set<String> = []
    var glassesAdded = false
    var hipaaMode = false
    var simpleMode = false
    var fieldAssistActive = false
    var fieldJobOpen = false
    var memoryOn = true
    var captionHistoryExists = false
    var hasUsableModel = true
    /// The model in use runs on this phone, so a turn's words stay here.
    var modelOnDevice = false
    /// The same answer the grid's photo tiles use (`HomeGridPhotoPolicy`).
    var modelCanSee = true
    var isOnline = true
    var homeControlAvailable = false
    var myManualsPermitted = false
    var myManualsHaveContent = false
    /// Hub categories this phone does not show: Simple Mode's, and whatever an organisation locked.
    var unreachableSettings: Set<SettingsCategoryID> = []
}

/// The one step between a scenario and running it. Each says what to do in plain words and where
/// to do it, so nothing else needs to know how a step is worded.
enum ScenarioSetupStep: Equatable, Sendable {
    case chooseModel
    case chooseVisionModel
    case turnOnTool
    case turnOnFeature
    case turnOnMemory
    case setUpHome
    case addManual
    case runCaptions

    var instruction: String {
        switch self {
        case .chooseModel: return String(localized: "Choose an AI model first.")
        case .chooseVisionModel: return String(localized: "Choose a model that can see images.")
        case .turnOnTool: return String(localized: "Turn this on in Settings, under Tools.")
        case .turnOnFeature: return String(localized: "This is turned off in Settings.")
        case .turnOnMemory: return String(localized: "Turn on User Memory first.")
        case .setUpHome: return String(localized: "Set up Apple Home or Home Assistant first.")
        case .addManual: return String(localized: "Add a manual to My Manuals first.")
        case .runCaptions: return String(localized: "Turn on captions during your next meeting, then ask.")
        }
    }

    /// The hub category that holds this step, when one does. `turnOnFeature` has none: the switch
    /// could be on several screens, so the row says so and the person opens Settings.
    var destination: SettingsCategoryID? {
        switch self {
        case .chooseModel, .chooseVisionModel, .turnOnMemory: return .intelligence
        case .turnOnTool: return .tools
        case .setUpHome: return .connections
        case .addManual: return .myManuals
        case .turnOnFeature, .runCaptions: return nil
        }
    }
}

/// Where a scenario stands on this phone (Decision 4: it never promises what the phone cannot do).
enum ScenarioReadiness: Equatable, Sendable {
    case ready
    case needsSetup(ScenarioSetupStep)
    case hidden

    var isVisible: Bool { self != .hidden }

    /// Pure. Hidden comes first: a reason a person cannot act on must never be dressed as a step.
    static func evaluate(_ scenario: Scenario, in context: ScenarioContext) -> ScenarioReadiness {
        guard !isHidden(scenario, in: context),
              !(scenario.kind == .photoPrompt && !context.isOnline && !context.modelOnDevice) else {
            return .hidden
        }
        guard let step = setupStep(for: scenario, in: context) else { return .ready }
        // Simple Mode's settings are out of reach on purpose, and an organisation's locked ones
        // are too. A step the person cannot take is not a step.
        if context.simpleMode { return .hidden }
        if let destination = step.destination, context.unreachableSettings.contains(destination) {
            return .hidden
        }
        return .needsSetup(step)
    }

    private static func isHidden(_ scenario: Scenario, in context: ScenarioContext) -> Bool {
        if context.hipaaMode, wouldLeaveThePhone(scenario, in: context) { return true }
        let tools = scenario.toolNames
        if !tools.isDisjoint(with: context.closedTools) { return true }
        // Closed by the mode, whatever the person's own list says about the tool.
        if context.hipaaMode, !tools.isDisjoint(with: Config.hipaaDisabledTools) { return true }
        // Off, and not by a switch the person holds: not registered, the wrong mode, HIPAA, or not
        // offered to the model in use.
        let reachable = context.availableTools.union(context.toolsTurnedOff)
            .union(context.featureToolsOff)
        if !tools.isSubset(of: reachable) { return true }
        for need in scenario.needs {
            switch need {
            case .glasses where !context.glassesAdded: return true
            case .fieldAssist where !context.fieldAssistActive: return true
            case .fieldJobOpen where !context.fieldJobOpen: return true
            case .myManuals where !context.myManualsPermitted || context.hipaaMode: return true
            default: continue
            }
        }
        return false
    }

    /// Whether a turn from this scenario would take something off the phone. HIPAA hides these, and
    /// where the call is close it errs on hiding:
    ///   - With a cloud model every turn leaves, so every scenario is hidden. `hipaaLocalOnly` may
    ///     be off and such a turn may be allowed, but a shortcut to one should not be offered.
    ///   - A picture can be a chart (see `Config.hipaaDisabledTools` on `reading_session`).
    ///   - A tool not classed `.local` reaches beyond the phone, or may.
    static func wouldLeaveThePhone(_ scenario: Scenario, in context: ScenarioContext) -> Bool {
        guard context.modelOnDevice else { return true }
        if scenario.kind == .photoPrompt || scenario.reachesOutsidePhone { return true }
        return scenario.toolNames.contains { OfflineToolPolicy.availability(of: $0) != .local }
    }

    private static func setupStep(for scenario: Scenario, in context: ScenarioContext) -> ScenarioSetupStep? {
        guard context.hasUsableModel else { return .chooseModel }
        if scenario.kind == .photoPrompt && !context.modelCanSee { return .chooseVisionModel }
        let tools = scenario.toolNames
        if !tools.isDisjoint(with: context.toolsTurnedOff) { return .turnOnTool }
        if !tools.isDisjoint(with: context.featureToolsOff) { return .turnOnFeature }
        if scenario.needs.contains(.memoryOn), !context.memoryOn { return .turnOnMemory }
        if scenario.needs.contains(.homeControl), !context.homeControlAvailable { return .setUpHome }
        if scenario.needs.contains(.myManuals), !context.myManualsHaveContent { return .addManual }
        if scenario.needs.contains(.captionHistory), !context.captionHistoryExists { return .runCaptions }
        return nil
    }

    /// Every visible scenario with where it stands, in catalogue order.
    static func visible(_ scenarios: [Scenario], in context: ScenarioContext) -> [ScenarioEntry] {
        scenarios.compactMap { scenario in
            let readiness = evaluate(scenario, in: context)
            return readiness.isVisible ? ScenarioEntry(scenario: scenario, readiness: readiness) : nil
        }
    }
}

/// A scenario and where it stands.
struct ScenarioEntry: Identifiable, Equatable, Sendable {
    let scenario: Scenario
    let readiness: ScenarioReadiness
    var id: String { scenario.id }

    /// What a card or row says under the title: the step, or the situation.
    var detail: String {
        if case .needsSetup(let step) = readiness { return step.instruction }
        return scenario.situation
    }
}

/// Which tools a turn on this model would really be offered. The on-device paths carry reduced
/// lists, and with no signal only some tools work, so a scenario must not promise the rest. Pure.
enum ScenarioToolOffer {
    /// Whether the active model has what it needs to take a turn: `LLMService`'s own rule for a
    /// configuration. A model signed in through an account has no key. A local model is taken as
    /// present, because only a downloaded one becomes active.
    static func modelCanAnswer(provider: LLMProvider, apiKey: String, baseURL: String,
                               accountConnected: Bool) -> Bool {
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch provider {
        case .custom: return !baseURL.isEmpty
        case .anthropic, .xai: return hasKey || accountConnected
        default: return !provider.requiresAPIKey || hasKey
        }
    }

    static func offered(_ tools: Set<String>, provider: LLMProvider?, fieldAssistActive: Bool,
                        isOnline: Bool, libraryHasManuals: Bool) -> Set<String> {
        var offered = tools
        if provider == .local {
            offered = Set(LLMService.localToolNames(registered: Array(tools), offlineHandoff: false,
                                                    libraryHasManuals: libraryHasManuals))
        } else if provider == .appleOnDevice {
            // The priority names, not the budget cut: the cut needs the definitions' sizes, and
            // this is a promise about what a turn is offered, so it can only over-read by a little.
            offered = Set(AppleOnDeviceToolSet.priorityNames(
                registered: Array(tools), fieldAssistActive: fieldAssistActive, offlineHandoff: false,
                libraryHasManuals: libraryHasManuals))
        }
        return isOnline ? offered : offered.filter(OfflineToolPolicy.isOfferedOffline)
    }
}

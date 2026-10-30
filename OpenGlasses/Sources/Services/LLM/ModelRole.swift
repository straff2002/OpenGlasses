import Foundation

/// A job in the app that a model does (Plan KA, Design 8–13). `ModelKind` says what a listed model
/// *is*; a role says which job uses it. One key now reaches models of several kinds, so one key can
/// serve several roles — each with its own picker, and each chosen, never switched on silently.
///
/// The roles that exist as settings today are those settings, not copies of them: Assistant is the
/// active model, Voice is the voice-engine preference, Live is the active live model, and Dictation
/// is the recogniser preference. Vision is the one new value (`Config.visionRoleModelId`).
enum ModelRole: String, CaseIterable, Identifiable, Sendable {
    case assistant
    case vision
    case voice
    case live
    case dictation
    /// Defined so the kinds line up, never shown: no cloud image tool exists yet, and the tool —
    /// with its camera, privacy and cost wording — is its own plan (Design 12).
    case images

    var id: String { rawValue }

    /// The roles Settings shows, in order. Images waits for its tool.
    static let shown: [ModelRole] = [.assistant, .vision, .voice, .live, .dictation]

    /// The kind of model the role takes.
    var kind: ModelKind {
        switch self {
        case .assistant, .vision: return .chat
        case .voice: return .speech
        case .live: return .realtime
        case .dictation: return .transcription
        case .images: return .image
        }
    }

    var title: String {
        switch self {
        case .assistant: return String(localized: "Assistant")
        case .vision: return String(localized: "Vision")
        case .voice: return String(localized: "Voice")
        case .live: return String(localized: "Live")
        case .dictation: return String(localized: "Dictation")
        case .images: return String(localized: "Images")
        }
    }

    var icon: String {
        switch self {
        case .assistant: return "bubble.left.and.text.bubble.right"
        case .vision: return "eye"
        case .voice: return "speaker.wave.2"
        case .live: return "waveform"
        case .dictation: return "mic"
        case .images: return "photo"
        }
    }

    /// What the role's picker says the job is.
    var pickerFooter: String {
        switch self {
        case .assistant:
            return String(localized: "The assistant answers what you ask. Add models and keys under AI Models.")
        case .vision:
            return String(localized: "The model that looks at photos you ask about. It answers that question itself; the rest of the conversation stays with the assistant. With Automatic, the assistant looks if it can, otherwise the first model in your fallback order that can see photos.")
        case .voice:
            return String(localized: "The voice that speaks replies. A cloud voice is sent the text of each reply and uses that provider's key. Voices and speech models are set under Voice & Triggers.")
        case .live:
            return String(localized: "The model Live mode talks to. In Live mode your voice, and the camera when you share it, stream to that provider on its key. Add or edit live models under Realtime Models.")
        case .dictation:
            return String(localized: "The recogniser that turns your questions into text. A cloud recogniser is sent the audio of each question and uses that provider's key.")
        case .images:
            return ""
        }
    }
}

// MARK: - Inputs

/// What limits the roles: Medical local-only, HIPAA and an organisation's profile (Design 13).
struct ModelRoleRestrictions: Equatable, Sendable {
    /// Medical Compliance with Local LLM Only (`MedicalLLMRoutingPolicy.isEnforced`): nothing that
    /// leaves the phone is offered, and a role whose every option leaves it is off.
    var localOnly: Bool = false
    /// Medical Compliance on: cloud dictation is refused outright, local-only or not
    /// (`CloudDictationGate`).
    var hipaa: Bool = false
    /// Roles an organisation's profile has pinned: shown, read-only. No profile key pins a whole
    /// role today; the set carries it so the first one is one line.
    var orgPinned: Set<ModelRole> = []
    /// Roles whose cloud options an organisation's profile has pinned off (cloud dictation).
    var orgCloudOff: Set<ModelRole> = []
    /// The organisation's name, for the locked row.
    var organizationName: String? = nil

    static let none = ModelRoleRestrictions()
}

/// Everything the role decisions read, gathered by the caller so the decisions stay pure:
/// saved models (each with its key in the Keychain), saved live models, which cloud voices and
/// recognisers have credentials, and the restrictions.
struct ModelRoleInputs: Equatable {
    var savedModels: [ModelConfig]
    var realtimeModels: [RealtimeModelConfig] = []
    /// Cloud voices whose key or sign-in is saved.
    var voiceCredentials: Set<TTSEngine> = []
    /// Cloud recognisers whose key is saved.
    var dictationCredentials: Set<CloudDictationProvider> = []
    var restrictions: ModelRoleRestrictions = .none
    /// The day the decisions are made on, so a model past its shutdown day can't be chosen and one
    /// close to it says so (Plan KA P2). Injected by tests.
    var today: Date = Date()
}

/// Each role's current value, read from the settings the roles are.
struct ModelRoleState: Equatable {
    var assistantId: String
    var visionModelId: String? = nil
    var voice: TTSEnginePreference = .auto
    /// The live model Live mode uses, or nil when none is saved.
    var liveModelId: String? = nil
    var dictation: ASREnginePreference = .auto
}

// MARK: - Options

/// One row of a role's picker.
struct ModelRoleOption: Identifiable, Equatable {
    enum Choice: Hashable {
        /// A saved model (Assistant, Vision).
        case model(configId: String)
        /// Vision with no model of its own: the photo goes the way it went before roles.
        case visionAutomatic
        /// A new saved model for photos: the key of `sourceConfigId` with the provider's vision
        /// default, made on the tap that chooses it.
        case newVisionModel(sourceConfigId: String, model: String)
        case voice(TTSEnginePreference)
        /// A saved live model.
        case liveModel(id: String)
        /// A live model made from a saved chat key on the tap that chooses it.
        case newLiveModel(providerID: String, model: String, sourceConfigId: String)
        case dictation(ASREnginePreference)

        var id: String {
            switch self {
            case .model(let id): return "model:\(id)"
            case .visionAutomatic: return "vision:auto"
            case .newVisionModel(let source, let model): return "new-vision:\(source):\(model)"
            case .voice(let preference): return "voice:\(preference.rawValue)"
            case .liveModel(let id): return "live:\(id)"
            case .newLiveModel(let provider, let model, let source): return "new-live:\(provider):\(model):\(source)"
            case .dictation(let preference): return "dictation:\(preference.rawValue)"
            }
        }
    }

    let choice: Choice
    let title: String
    let subtitle: String?
    /// Whether choosing it sends the wearer's data off the phone.
    let leavesPhone: Bool
    /// Why it can't be chosen ("Retired", "Needs a connection the app doesn't have yet"); nil when
    /// it can. A row with one is shown dimmed, not as a choice.
    var unavailableLabel: String? = nil
    /// A line a choosable row adds, such as when its provider retires it.
    var note: String? = nil

    var id: String { choice.id }
    var isChoosable: Bool { unavailableLabel == nil }

    /// The option with a model status's label or note applied.
    func applying(_ status: ModelChoiceStatus) -> ModelRoleOption {
        var option = self
        option.unavailableLabel = status.unavailableLabel
        option.note = status.note
        return option
    }
}

/// Whether a role's picker can be used.
enum ModelRoleAvailability: Equatable {
    case available
    /// Every option leaves the phone and Medical local-only is on.
    case offUnderLocalOnly
    /// An organisation's profile pinned the role.
    case pinned(organization: String?)

    var isEditable: Bool { self == .available }
}

/// A role a newly added key could take on, for the "this key can also…" card (Design 9).
struct ModelRoleSuggestion: Identifiable, Equatable {
    let role: ModelRole
    let choice: ModelRoleOption.Choice
    /// What the role does, in a few words: "Speak replies".
    let summary: String
    /// Where the data goes and whose quota it spends — every suggestion is a new destination.
    let destination: String

    var id: String { role.rawValue }
}

// MARK: - Defaults

/// Each provider's default model per role: the one its docs recommend for that use, so choosing a
/// role is one tap. Nil when the provider has no model for the role in this app, or when its
/// endpoint takes no model id (xAI's voice).
enum ModelRoleDefaults {

    /// - Parameter fromSuggestion: the role is being switched on from the key's card. Where a
    ///   provider has more than one live model, the cheaper one is the default then (decision 6).
    static func model(for role: ModelRole, provider: LLMProvider, fromSuggestion: Bool = false) -> String? {
        switch role {
        case .assistant:
            return provider.defaultModel
        case .vision:
            // A cheap, fast model that takes images; a provider's own default where that is one.
            // Each was read against its provider's docs on 2026-10-30 (Plan KA P2) and takes
            // image input there. Groq's only image model is a preview; the owner took it anyway.
            switch provider {
            case .anthropic: return "claude-haiku-5-5"
            case .openai: return "gpt-5.4-mini"
            case .gemini, .geminiVertex: return provider.defaultModel
            case .xai: return provider.defaultModel
            case .mistral: return "mistral-small-latest"
            case .deepseek: return "deepseek-flash"
            case .zai: return "glm-5.3-flash"
            case .qwen: return "qwen3.7-plus"
            case .minimax: return "MiniMax-M3.1-Flash"
            case .openrouter: return "anthropic/claude-haiku-5.5"
            case .groq: return "qwen/qwen3.8-27b"
            default: return nil
            }
        case .voice:
            switch provider {
            // OpenAI retires every model its speech endpoint takes on 2027-01-06, this one
            // included, and names no replacement on that endpoint; Plan KB decides what follows.
            case .openai: return CloudVoiceRequests.openAISpeechModel
            case .gemini: return CloudVoiceRequests.defaultGeminiSpeechModel
            default: return nil
            }
        case .live:
            switch provider {
            case .openai: return fromSuggestion ? OpenAIRealtimeModelRetirement.mini : OpenAIRealtimeModelRetirement.full
            case .gemini: return GeminiLiveModelPolicy.offlineFallbackModel
            default: return nil
            }
        case .dictation:
            return provider == .openai ? OpenAIDictationRequest.model : nil
        case .images:
            // No image tool yet (Design 12).
            return nil
        }
    }
}

// MARK: - Decisions

/// The pure role decisions: which roles a key offers, each role's candidates, its availability
/// under the restrictions, its current value, and what a newly added key's card suggests.
enum ModelRoleCatalog {

    // MARK: Which roles a key offers

    /// The roles a saved model's provider can serve in this app — where the app has a transport
    /// for that provider and job — before its list is consulted. A key on another server than the
    /// provider's own never counts for voice, Live or dictation: it belongs to that server.
    static func providerRoles(_ config: ModelConfig) -> Set<ModelRole> {
        var roles: Set<ModelRole> = [.assistant]
        let provider = config.llmProvider
        let hasKey = !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ModelFallbackChain.candidate(from: config).supportsVision
            || (hasKey && ModelRoleDefaults.model(for: .vision, provider: provider) != nil) {
            roles.insert(.vision)
        }
        guard hasKey else { return roles }
        switch provider {
        case .openai where CloudVoiceCredentials.isHost(config.baseURL, "api.openai.com"):
            roles.formUnion([.voice, .live, .dictation])
        case .gemini where CloudVoiceCredentials.isHost(config.baseURL, "generativelanguage.googleapis.com"):
            roles.formUnion([.voice, .live])
        case .xai where CloudVoiceCredentials.isHost(config.baseURL, "x.ai"):
            roles.insert(.voice)
        default:
            break
        }
        return roles
    }

    /// Roles whose models the provider's list is known to carry, so a loaded list that has none of
    /// them means this key can't do that job (OpenAI's list carries speech, transcription and
    /// realtime models; Gemini's its speech and Live models). Elsewhere the provider decides.
    private static func listConfirms(_ provider: LLMProvider) -> Set<ModelRole> {
        switch provider {
        case .openai: return [.voice, .live, .dictation]
        case .gemini: return [.voice, .live]
        default: return []
        }
    }

    /// The roles a key offers: the provider's roles, less any its loaded list shows it can't do —
    /// no model of the role's kind that the app can reach and that is still answering (an OpenAI
    /// list whose only live model is `gpt-live-1` offers no Live). Images is never offered
    /// (Design 12).
    static func roles(offeredBy config: ModelConfig, listed: [ModelFetcher.RemoteModel]? = nil,
                      today: Date = Date()) -> Set<ModelRole> {
        var roles = providerRoles(config)
        guard let listed, !listed.isEmpty else { return roles }
        let provider = config.llmProvider
        for role in listConfirms(provider) where !listed.contains(where: { model in
            ModelChoiceStatus.of(provider: provider, id: model.id, kind: model.kind, shutdown: model.shutdown,
                                 for: role, today: today).isChoosable
        }) {
            roles.remove(role)
        }
        return roles
    }

    // MARK: Candidates

    /// Every option a role's picker offers, across every saved key, plus the role's on-device or
    /// built-in options — less anything the restrictions rule out.
    static func options(for role: ModelRole, inputs: ModelRoleInputs) -> [ModelRoleOption] {
        let all = unrestrictedOptions(for: role, inputs: inputs)
        let restrictions = inputs.restrictions
        return all.filter { option in
            if restrictions.localOnly && option.leavesPhone { return false }
            if restrictions.orgCloudOff.contains(role) && option.leavesPhone { return false }
            if role == .dictation && restrictions.hipaa && option.leavesPhone { return false }
            return true
        }
    }

    private static func unrestrictedOptions(for role: ModelRole, inputs: ModelRoleInputs) -> [ModelRoleOption] {
        switch role {
        case .assistant:
            return inputs.savedModels.map { config in
                ModelRoleOption(choice: .model(configId: config.id), title: config.name,
                                subtitle: "\(config.providerDisplayName) · \(config.model)",
                                leavesPhone: !isOnDevice(config.llmProvider))
                    .applying(savedModelStatus(config, role: .assistant, today: inputs.today))
            }
        case .vision:
            var options = [ModelRoleOption(
                choice: .visionAutomatic, title: String(localized: "Automatic"),
                subtitle: String(localized: "The assistant, or the next model that can see photos"),
                leavesPhone: false)]
            options += inputs.savedModels
                .filter { ModelFallbackChain.candidate(from: $0).supportsVision }
                .map { config in
                    ModelRoleOption(choice: .model(configId: config.id), title: config.name,
                                    subtitle: "\(config.providerDisplayName) · \(config.model)",
                                    leavesPhone: !isOnDevice(config.llmProvider))
                        .applying(savedModelStatus(config, role: .vision, today: inputs.today))
                }
            return options
        case .voice:
            return TTSEnginePreference.allCases.compactMap { preference in
                if let engine = preference.cloudEngine, !inputs.voiceCredentials.contains(engine) { return nil }
                return ModelRoleOption(choice: .voice(preference), title: preference.displayName,
                                       subtitle: voiceSubtitle(preference),
                                       leavesPhone: preference == .auto ? !inputs.voiceCredentials.isEmpty
                                                                         : preference.cloudEngine != nil,
                                       note: voiceNote(preference, today: inputs.today))
            }
        case .live:
            var options = inputs.realtimeModels.map { model in
                ModelRoleOption(choice: .liveModel(id: model.id), title: model.name,
                                subtitle: model.profile?.title ?? String(localized: "Unsupported protocol version"),
                                leavesPhone: true)
                    .applying(liveModelStatus(model, today: inputs.today))
            }
            // A saved chat key whose provider has a live model, and no live model saved for that
            // provider yet: offered, made on the tap that chooses it (Design 11).
            var offeredProviders = Set(inputs.realtimeModels.map(\.providerID))
            for config in inputs.savedModels where providerRoles(config).contains(.live) {
                guard let providerID = liveProviderID(config.llmProvider),
                      !offeredProviders.contains(providerID),
                      let model = ModelRoleDefaults.model(for: .live, provider: config.llmProvider),
                      ModelChoiceStatus.of(provider: config.llmProvider, id: model,
                                           kind: ModelKindClassifier.kind(provider: config.llmProvider, id: model),
                                           for: .live, today: inputs.today).isChoosable else { continue }
                offeredProviders.insert(providerID)
                options.append(ModelRoleOption(
                    choice: .newLiveModel(providerID: providerID, model: model, sourceConfigId: config.id),
                    title: liveTitle(providerID),
                    subtitle: String(localized: "With the key saved for \(config.name) · \(model)"),
                    leavesPhone: true))
            }
            return options
        case .dictation:
            return ASREnginePreference.allCases.compactMap { preference in
                if let provider = preference.cloudEngine.flatMap(CloudDictationProvider.init(engine:)),
                   !inputs.dictationCredentials.contains(provider) { return nil }
                return ModelRoleOption(choice: .dictation(preference), title: preference.displayName,
                                       subtitle: dictationSubtitle(preference), leavesPhone: preference.isCloud)
            }
        case .images:
            return []
        }
    }

    // MARK: Availability

    static func availability(of role: ModelRole, inputs: ModelRoleInputs) -> ModelRoleAvailability {
        if inputs.restrictions.orgPinned.contains(role) {
            return .pinned(organization: inputs.restrictions.organizationName)
        }
        if inputs.restrictions.localOnly {
            // Vision's Automatic is not a model; with no on-phone model that sees, the role is off.
            let real = options(for: role, inputs: inputs).filter { $0.choice != .visionAutomatic }
            if real.isEmpty { return .offUnderLocalOnly }
        }
        return .available
    }

    // MARK: Current value

    /// The choice that is the role's value now, or nil when nothing is set (no live model saved).
    static func selected(_ role: ModelRole, state: ModelRoleState) -> ModelRoleOption.Choice? {
        switch role {
        case .assistant: return .model(configId: state.assistantId)
        case .vision: return state.visionModelId.map { .model(configId: $0) } ?? .visionAutomatic
        case .voice: return .voice(state.voice)
        case .live: return state.liveModelId.map { .liveModel(id: $0) }
        case .dictation: return .dictation(state.dictation)
        case .images: return nil
        }
    }

    /// The choice a picker marks: the stored value, except a cloud recogniser the restrictions
    /// rule out reads as Automatic — what the turn actually runs — with the stored choice left alone.
    static func effectiveSelection(_ role: ModelRole, state: ModelRoleState,
                                   inputs: ModelRoleInputs) -> ModelRoleOption.Choice? {
        let stored = selected(role, state: state)
        if role == .dictation, let stored,
           !options(for: role, inputs: inputs).contains(where: { $0.choice == stored }) {
            return .dictation(.auto)
        }
        return stored
    }

    /// What a role's row in Settings says it is set to.
    static func summary(of role: ModelRole, state: ModelRoleState, inputs: ModelRoleInputs) -> String {
        switch availability(of: role, inputs: inputs) {
        case .offUnderLocalOnly: return String(localized: "Off")
        case .pinned, .available: break
        }
        guard let choice = effectiveSelection(role, state: state, inputs: inputs) else { return String(localized: "Not set") }
        if let option = unrestrictedOptions(for: role, inputs: inputs).first(where: { $0.choice == choice }) {
            return option.title
        }
        return String(localized: "Not set")
    }

    /// Whether the wearer has already chosen this role, so a key's card doesn't offer it again.
    /// Voice and Dictation count as set once they are anything but Automatic; Live once a live
    /// model is saved; Vision once a model is chosen or the assistant can see photos itself.
    static func isSet(_ role: ModelRole, state: ModelRoleState, inputs: ModelRoleInputs) -> Bool {
        switch role {
        case .assistant: return !state.assistantId.isEmpty
        case .vision:
            if state.visionModelId != nil { return true }
            guard let assistant = inputs.savedModels.first(where: { $0.id == state.assistantId }) else { return false }
            return ModelFallbackChain.candidate(from: assistant).supportsVision
        case .voice: return state.voice != .auto
        case .live: return state.liveModelId != nil || !inputs.realtimeModels.isEmpty
        case .dictation: return state.dictation != .auto
        case .images: return true
        }
    }

    /// A saved Vision choice that still names a saved model that sees photos, else nil — so a
    /// deleted model, or one switched to text-only, reads as Automatic.
    static func visionModelId(stored: String?, saved: [ModelConfig]) -> String? {
        guard let stored, !stored.isEmpty,
              let config = saved.first(where: { $0.id == stored }),
              ModelFallbackChain.candidate(from: config).supportsVision else { return nil }
        return stored
    }

    // MARK: The key's card

    /// What a newly added key's card offers: each role the key can serve that isn't set yet and
    /// that the restrictions allow, never the assistant (the key was added as a chat model) and
    /// never Images. Nothing here switches anything on; the card's taps do.
    static func suggestions(for added: ModelConfig, listed: [ModelFetcher.RemoteModel]? = nil,
                            inputs: ModelRoleInputs, state: ModelRoleState) -> [ModelRoleSuggestion] {
        let restrictions = inputs.restrictions
        // Every suggestion leaves the phone.
        guard !restrictions.localOnly else { return [] }
        let offered = roles(offeredBy: added, listed: listed, today: inputs.today)
        let vendor = vendorName(added.llmProvider)
        var suggestions: [ModelRoleSuggestion] = []
        for role in [ModelRole.vision, .voice, .live, .dictation] where offered.contains(role) {
            guard !restrictions.orgPinned.contains(role), !restrictions.orgCloudOff.contains(role),
                  !(role == .dictation && restrictions.hipaa),
                  !isSet(role, state: state, inputs: inputs) else { continue }
            switch role {
            case .vision:
                let choice: ModelRoleOption.Choice
                if ModelFallbackChain.candidate(from: added).supportsVision,
                   savedModelStatus(added, role: .vision, today: inputs.today).isChoosable {
                    choice = .model(configId: added.id)
                } else if let model = ModelRoleDefaults.model(for: .vision, provider: added.llmProvider) {
                    choice = .newVisionModel(sourceConfigId: added.id, model: model)
                } else { continue }
                suggestions.append(.init(
                    role: role, choice: choice, summary: String(localized: "Look at photos"),
                    destination: String(localized: "Photos you ask about go to \(vendor), on this key's quota.")))
            case .voice:
                guard let preference = voicePreference(added.llmProvider) else { continue }
                suggestions.append(.init(
                    role: role, choice: .voice(preference), summary: String(localized: "Speak replies"),
                    destination: String(localized: "The text of each spoken reply goes to \(vendor), on this key's quota.")))
            case .live:
                guard let providerID = liveProviderID(added.llmProvider),
                      let model = ModelRoleDefaults.model(for: .live, provider: added.llmProvider, fromSuggestion: true),
                      ModelChoiceStatus.of(provider: added.llmProvider, id: model,
                                           kind: ModelKindClassifier.kind(provider: added.llmProvider, id: model),
                                           for: .live, today: inputs.today).isChoosable
                else { continue }
                suggestions.append(.init(
                    role: role, choice: .newLiveModel(providerID: providerID, model: model, sourceConfigId: added.id),
                    summary: String(localized: "Run Live mode"),
                    destination: String(localized: "In Live mode your voice, and the camera when you share it, stream to \(vendor), on this key's quota.")))
            case .dictation:
                suggestions.append(.init(
                    role: role, choice: .dictation(.openAI), summary: String(localized: "Take dictation"),
                    destination: String(localized: "The audio of each question you ask goes to \(vendor), charged to this key.")))
            case .assistant, .images:
                continue
            }
        }
        return suggestions
    }

    /// The card's heading: "This Gemini key can also…".
    static func cardTitle(for added: ModelConfig) -> String {
        let name: String
        switch added.llmProvider {
        case .gemini: name = "Gemini"
        default: name = vendorName(added.llmProvider)
        }
        return String(localized: "This \(name) key can also…")
    }

    // MARK: Building what a choice makes

    /// The live model a `.newLiveModel` choice saves: the provider's template, the source key and
    /// the chosen model. The key is copied into the live model's own Keychain entry on the
    /// wearer's tap — a chat key is never used for Live without that tap.
    static func liveModel(providerID: String, model: String, apiKey: String,
                          id: String = UUID().uuidString) -> RealtimeModelConfig? {
        guard var config = RealtimeProviderCatalog.template(providerID)?.modelConfiguration() else { return nil }
        config.id = id
        config.model = model
        config.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    /// The saved model a `.newVisionModel` choice adds: the source's provider, address and key with
    /// the provider's vision default.
    static func visionModel(from source: ModelConfig, model: String, id: String = UUID().uuidString) -> ModelConfig {
        var config = source
        config.id = id
        config.model = model
        config.name = String(localized: "\(source.providerDisplayName) for photos")
        config.supportsVision = nil
        config.reasoningEffort = nil
        return config
    }

    // MARK: What a saved model can still do

    /// A saved model's status for the assistant or Vision: its kind (a speech model saved as a
    /// chat model can't answer), and its provider's shutdown day.
    static func savedModelStatus(_ config: ModelConfig, role: ModelRole, today: Date) -> ModelChoiceStatus {
        let provider = config.llmProvider
        let kind = ModelKindClassifier.kind(provider: provider, typedID: config.model) ?? .chat
        return ModelChoiceStatus.of(provider: provider, id: config.model, kind: kind, for: role, today: today)
    }

    /// A saved live model's status. Only OpenAI's ids are read: its realtime socket takes the
    /// `gpt-realtime…` models and not `gpt-live-1`, and its shutdown days are known. Gemini Live
    /// picks the model it connects with from the account's own list, and a compatible server's
    /// names are its own, so both stay choosable.
    static func liveModelStatus(_ model: RealtimeModelConfig, today: Date) -> ModelChoiceStatus {
        guard model.providerID == "openai" else { return .choosable(retiring: nil) }
        let id = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = ModelShutdownCalendar.shutdown(provider: .openai, id: id)
        if let day, day.hasPassed(on: today) { return .retired(day) }
        let kind = ModelKindClassifier.kind(provider: .openai, id: id)
        if kind == .realtime, !ModelTransport.canUse(provider: .openai, id: id, kind: kind, for: .live) {
            return .needsConnection
        }
        if let day, day.isWithin(days: ModelShutdownCalendar.warningDays, of: today) {
            return .choosable(retiring: day)
        }
        return .choosable(retiring: nil)
    }

    /// The OpenAI voice's model retires within the warning window: say when on its row.
    private static func voiceNote(_ preference: TTSEnginePreference, today: Date) -> String? {
        guard preference == .openAI,
              let day = ModelShutdownCalendar.shutdown(provider: .openai, id: CloudVoiceRequests.openAISpeechModel),
              !day.hasPassed(on: today), day.isWithin(days: ModelShutdownCalendar.warningDays, of: today)
        else { return nil }
        return ModelChoiceStatus.retiresLabel(day)
    }

    // MARK: Helpers

    static func isOnDevice(_ provider: LLMProvider) -> Bool {
        provider == .local || provider == .appleOnDevice
    }

    /// The live-model catalog entry for a chat provider, where the app has one.
    static func liveProviderID(_ provider: LLMProvider) -> String? {
        switch provider {
        case .openai: return "openai"
        case .gemini: return "gemini"
        default: return nil
        }
    }

    private static func liveTitle(_ providerID: String) -> String {
        providerID == "gemini" ? String(localized: "Gemini Live") : String(localized: "OpenAI Realtime")
    }

    private static func voicePreference(_ provider: LLMProvider) -> TTSEnginePreference? {
        switch provider {
        case .openai: return .openAI
        case .xai: return .xai
        case .gemini: return .gemini
        default: return nil
        }
    }

    /// The company the data goes to, as the card names it.
    static func vendorName(_ provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini, .geminiVertex: return "Google"
        case .xai: return "xAI"
        case .mistral: return "Mistral"
        default: return provider.displayName
        }
    }

    private static func voiceSubtitle(_ preference: TTSEnginePreference) -> String? {
        switch preference {
        case .auto: return String(localized: "A cloud voice if one is set up, otherwise on this phone")
        case .kokoro, .system: return String(localized: "On this phone")
        case .elevenLabs, .openAI, .xai, .gemini:
            let vendor = preference.cloudEngine?.vendorName ?? ""
            return String(localized: "The text of each reply goes to \(vendor)")
        }
    }

    private static func dictationSubtitle(_ preference: ASREnginePreference) -> String? {
        switch preference {
        case .auto: return String(localized: "Apple's recogniser, or the one on this phone once it's downloaded")
        case .onDevice: return String(localized: "On this phone")
        case .appleSpeech: return String(localized: "Apple's recogniser")
        case .deepgram, .openAI:
            let vendor = preference.cloudEngine.flatMap(CloudDictationProvider.init(engine:))?.vendorName ?? ""
            return String(localized: "The audio of each question goes to \(vendor)")
        }
    }
}

// MARK: - Live values

extension ModelRoleInputs {
    /// The inputs as they stand: saved models and live models from the Keychain, which cloud
    /// voices and recognisers have credentials, and the medical and organisation limits.
    @MainActor static var live: ModelRoleInputs {
        let saved = Config.savedModels
        var voices: Set<TTSEngine> = []
        if !Config.elevenLabsAPIKey.isEmpty { voices.insert(.elevenLabs) }
        if !CloudVoiceCredentials.openAIKey(savedModels: saved, legacyKey: Config.openAIAPIKey).isEmpty {
            voices.insert(.openAI)
        }
        if CloudVoiceCredentials.xaiSource(savedModels: saved,
                                           accountConnected: XAIOAuthService.shared.isConnected) != .none {
            voices.insert(.xai)
        }
        if !CloudVoiceCredentials.geminiKey(savedModels: saved).isEmpty { voices.insert(.gemini) }
        var recognisers: Set<CloudDictationProvider> = []
        if !Config.deepgramAPIKey.isEmpty { recognisers.insert(.deepgram) }
        if !Config.dictationOpenAIKey.isEmpty { recognisers.insert(.openAI) }
        let restrictions = ModelRoleRestrictions(
            localOnly: MedicalLLMRoutingPolicy.isEnforced(hipaaMode: Config.hipaaMode, localOnly: Config.hipaaLocalOnly),
            hipaa: Config.hipaaMode,
            orgPinned: [],
            orgCloudOff: PolicyEnvelope.isLocked(.cloudDictationEnabled) ? [.dictation] : [],
            organizationName: PolicyEnvelope.organizationName)
        return ModelRoleInputs(savedModels: saved, realtimeModels: Config.savedRealtimeModels,
                               voiceCredentials: voices, dictationCredentials: recognisers,
                               restrictions: restrictions)
    }
}

extension ModelRoleState {
    /// Each role's value from the setting it is.
    static var live: ModelRoleState {
        ModelRoleState(assistantId: Config.activeModelId,
                       visionModelId: Config.visionRoleModelId,
                       voice: Config.ttsEnginePreference,
                       liveModelId: Config.liveRoleModelId,
                       dictation: Config.asrEnginePreference)
    }
}

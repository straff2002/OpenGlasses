import Foundation

/// App configuration and API keys
struct Config {
    /// Anthropic API key for Claude. Stored in the Keychain (see `KeychainService`).
    static var anthropicAPIKey: String {
        if let key = KeychainService.string(for: "anthropicAPIKey"), !key.isEmpty {
            return key
        }
        // No API key configured - set one via Settings
        return ""
    }

    static func setAnthropicAPIKey(_ key: String) {
        KeychainService.setString(key, for: "anthropicAPIKey")
    }

    // MARK: - Secret Storage Migration

    /// UserDefaults flag recording that the one-time secret migration has run.
    private static let secretsMigratedKey = "secretsMigratedToKeychain_v1"

    /// Plain-string secrets that historically lived in UserDefaults and now live in the Keychain.
    /// The UserDefaults key name is reused verbatim as the Keychain account.
    private static let migratableStringSecretKeys = [
        "anthropicAPIKey",
        "openAIAPIKey",
        "elevenLabsAPIKey",
        "perplexityAPIKey",
        "openClawGatewayToken",
        "homeAssistantToken",
        "broadcastStreamKey",
        "expertTurnCredential",
    ]

    /// JSON `Data` blobs that embed secrets (provider API keys, gateway tokens, MCP
    /// auth headers) and so must also move out of plaintext UserDefaults.
    private static let migratableDataSecretKeys = [
        modelsKey,        // "savedModelConfigs" — ModelConfig.apiKey
        "savedGateways",  // GatewayConfig.token
        "mcpServers",     // MCPServerConfig.headers (Authorization)
        "customAgentHarness", // CustomHarnessConfig.authValue (Plan N)
    ]

    /// Every credential currently configured on this device, as literal values.
    ///
    /// Only for *scrubbing* — the diagnostics report redactor matches these literally so a
    /// key that leaked into a log line is masked even when it has no recognisable shape
    /// (`SecretPatterns` can only spot the ones that announce themselves). Never format,
    /// log, or transmit the result.
    static var knownSecretValues: [String] {
        var values = migratableStringSecretKeys.compactMap { KeychainService.string(for: $0) }
        values.append(contentsOf: savedModels.map(\.apiKey))
        return values.filter { !$0.isEmpty }
    }

    /// One-time migration of plaintext secrets from UserDefaults into the Keychain.
    ///
    /// Copies any existing values into the Keychain, then removes the plaintext copy
    /// from UserDefaults so it no longer lands in unencrypted device backups. Only
    /// secrets move — non-secret prefs (toggles, onboarding flags, URLs, model names)
    /// stay in UserDefaults. Idempotent: the body runs at most once, and a value is
    /// removed from UserDefaults only after its Keychain write succeeds, so an
    /// interrupted/failed write is retried on the next launch rather than losing data.
    ///
    /// Call this once, early in app launch (before any secret is read).
    static func migrateSecretsToKeychainIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: secretsMigratedKey) else { return }

        var allMigrated = true

        for key in migratableStringSecretKeys {
            guard let value = defaults.string(forKey: key), !value.isEmpty else {
                defaults.removeObject(forKey: key)  // nothing/empty to migrate — clean up
                continue
            }
            if KeychainService.setString(value, for: key) {
                defaults.removeObject(forKey: key)
            } else {
                allMigrated = false  // keep plaintext until a later launch succeeds
            }
        }

        for key in migratableDataSecretKeys {
            guard let data = defaults.data(forKey: key), !data.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            if KeychainService.setData(data, for: key) {
                defaults.removeObject(forKey: key)
            } else {
                allMigrated = false
            }
        }

        if allMigrated {
            defaults.set(true, forKey: secretsMigratedKey)
            NSLog("[Config] Migrated provider secrets from UserDefaults to Keychain")
        } else {
            NSLog("[Config] Secret migration incomplete — will retry on next launch")
        }
    }

    // MARK: - Onboarding

    @UserDefaultsBacked("hasCompletedOnboarding", default: false) static var hasCompletedOnboarding: Bool

    static func setHasCompletedOnboarding(_ completed: Bool) { hasCompletedOnboarding = completed }

    /// Pure form of the onboarding gate, so the flag interaction below is testable without touching
    /// the Keychain that backs `savedModels`.
    ///
    /// `isReinstall` is the third input and it *forces* the flow on. See ``isReinstall(_:)`` for
    /// why: an install whose credentials outlived its preferences used to be waved straight past
    /// this gate, because credentials alone read as "already set up".
    static func needsOnboarding(hasCompletedOnboarding: Bool,
                                hasAnyAPIKey: Bool,
                                isReinstall: Bool = false) -> Bool {
        if isReinstall { return true }
        return !hasCompletedOnboarding && !hasAnyAPIKey
    }

    /// Pure form of ``isPastOnboarding``.
    static func isPastOnboarding(hasCompletedOnboarding: Bool,
                                 hasAnyAPIKey: Bool,
                                 isReinstall: Bool = false) -> Bool {
        !needsOnboarding(hasCompletedOnboarding: hasCompletedOnboarding,
                         hasAnyAPIKey: hasAnyAPIKey,
                         isReinstall: isReinstall)
    }

    /// True when the user hasn't completed onboarding and has no configured API keys — or when
    /// this launch is a reinstall, which gets the welcome-back page rather than a silent skip.
    static var needsOnboarding: Bool {
        needsOnboarding(
            hasCompletedOnboarding: hasCompletedOnboarding,
            hasAnyAPIKey: hasAnyAPIKey,
            isReinstall: isReinstallLaunch
        )
    }

    /// True when the user is past onboarding: they either finished it, or arrived with API keys
    /// already configured (an upgrade from a pre-onboarding build), which is the same condition
    /// that suppresses the onboarding screen.
    ///
    /// Services must gate on this rather than on `hasCompletedOnboarding`. The two differ for
    /// anyone who saved a key without finishing onboarding: `needsOnboarding` goes false so the
    /// screen never appears again and `hasCompletedOnboarding` is never set, leaving the glasses
    /// stack switched off forever with no in-app route to turn it on. Gating on the narrower flag
    /// meant even a completed registration would never surface as connected.
    static var isPastOnboarding: Bool { !needsOnboarding }

    // MARK: - Reinstall detection

    /// What a single launch can observe about whether this install's *preferences* survived.
    ///
    /// The Keychain outlives an app delete; `UserDefaults` does not. So after a delete and
    /// reinstall the app finds the user's keys and sign-ins intact and every preference gone —
    /// and the onboarding gate read that as "already set up" and skipped silently, dropping a
    /// returning user into a session with no statement of what carried over and what didn't.
    ///
    /// Pure values in, verdict out, so the rule is tested without a Keychain or a wiped device.
    struct LaunchProvenance: Equatable {
        /// The onboarding flag as stored — false when the key is absent, which is exactly the
        /// case a reinstall produces.
        var hasCompletedOnboarding: Bool
        /// At least one of the app's own long-lived defaults is present. This is the
        /// corroboration: without it, "no completion flag" cannot tell a wiped preference store
        /// apart from a user who simply never finished the flow.
        var hasLongLivedDefaults: Bool
        /// A credential survived: a saved provider key, or a connected account.
        var hasSavedCredentials: Bool

        init(hasCompletedOnboarding: Bool, hasLongLivedDefaults: Bool, hasSavedCredentials: Bool) {
            self.hasCompletedOnboarding = hasCompletedOnboarding
            self.hasLongLivedDefaults = hasLongLivedDefaults
            self.hasSavedCredentials = hasSavedCredentials
        }
    }

    /// Whether this launch is a reinstall: credentials on file with no preferences behind them.
    ///
    /// Deliberately conservative in both directions. No credential ⇒ never a reinstall (that is a
    /// plain fresh install, and it must stay byte-identical to what it was). Any surviving
    /// default ⇒ never a reinstall (the preference store is intact, so nothing was lost).
    static func isReinstall(_ provenance: LaunchProvenance) -> Bool {
        guard provenance.hasSavedCredentials else { return false }
        return !provenance.hasCompletedOnboarding && !provenance.hasLongLivedDefaults
    }

    /// Our own mark that this install has launched before, written by ``captureLaunchProvenance()``.
    /// Independent of the migrations below, so the verdict does not rest on their internals.
    private static let launchedBeforeKey = "hasLaunchedBefore"

    /// Defaults whose presence means this install has run before. Any one of them is enough —
    /// they are written by different subsystems, so no single change of behaviour elsewhere can
    /// quietly make every install look freshly reinstalled.
    static let longLivedDefaultsKeys = [launchedBeforeKey, "settingsJourneyState", secretsMigratedKey]

    /// Keychain items that outlive an app delete and stand in for "the user was signed in".
    /// Keys alone are not enough: the account-sign-in providers store no key at all.
    private static let accountCredentialKeychainKeys = [
        "claudeOAuthCredentials", "chatgptOAuthCredentials",
    ]

    /// At least one saved model carries a real provider key.
    static var hasAnyAPIKey: Bool { !savedModels.allSatisfy { $0.apiKey.isEmpty } }

    /// A provider key or a connected account is on file — anything that would let the app talk to
    /// a model without the user typing a thing.
    static var hasSurvivingCredentials: Bool {
        if hasAnyAPIKey { return true }
        return accountCredentialKeychainKeys.contains { KeychainService.data(for: $0) != nil }
    }

    private static var cachedLaunchProvenance: LaunchProvenance?

    /// Read the launch provenance **once, before any migration writes a default**, and remember it
    /// for the life of the process.
    ///
    /// Ordering is the whole point: the secrets migration and the settings-journey migration both
    /// write keys this reads, and both run in `OpenGlassesApp.init()`. Called after the UI-test
    /// seed and ahead of everything else, this sees the disk as the launch found it. Called late
    /// by accident, it would see the app's own writes and fall back to the pre-existing
    /// behaviour — a silent skip — rather than to anything worse.
    @discardableResult
    static func captureLaunchProvenance() -> LaunchProvenance {
        if let cachedLaunchProvenance { return cachedLaunchProvenance }
        let defaults = UserDefaults.standard
        // Read last: the saved-model getter can run the legacy migration, which writes.
        var credentials = hasSurvivingCredentials
        #if DEBUG
        // A simulator build with code signing off has no Keychain, so the UI test's reinstall
        // state cannot be seeded through the store that carries it. See
        // `UITestSupport.seededSurvivingCredentials`; nil on every other launch, and absent from
        // a Release binary.
        if let seeded = UITestSupport.seededSurvivingCredentials { credentials = seeded }
        #endif
        let provenance = LaunchProvenance(
            hasCompletedOnboarding: hasCompletedOnboarding,
            hasLongLivedDefaults: longLivedDefaultsKeys.contains { defaults.object(forKey: $0) != nil },
            hasSavedCredentials: credentials
        )
        cachedLaunchProvenance = provenance
        defaults.set(true, forKey: launchedBeforeKey)
        return provenance
    }

    /// The provenance this launch was started with.
    static var launchProvenance: LaunchProvenance { captureLaunchProvenance() }

    /// True while this launch is a reinstall the user has not yet answered for.
    ///
    /// Re-reads the completion flag rather than trusting the captured snapshot, so the moment
    /// onboarding is finished — by restoring *or* by setting up fresh, both of which set it — the
    /// gate goes back to its ordinary answer and the services that key off `isPastOnboarding`
    /// come up exactly as they always did.
    static var isReinstallLaunch: Bool {
        guard !hasCompletedOnboarding else { return false }
        return isReinstall(launchProvenance)
    }

    // MARK: - Wake Word

    /// The primary wake word phrase (user-configurable)
    static var wakePhrase: String {
        if let phrase = UserDefaults.standard.string(forKey: "wakePhrase"), !phrase.isEmpty {
            return phrase.lowercased()
        }
        // No "hey" prefix: matching is substring-based, so the bare name also catches anyone
        // who still says "hey openglasses" — one default covers both habits.
        return "openglasses"
    }

    static func setWakePhrase(_ phrase: String) {
        UserDefaults.standard.set(phrase.lowercased(), forKey: "wakePhrase")
    }

    /// Alternative spellings / misrecognitions of the wake phrase
    static var alternativeWakePhrases: [String] {
        if let alts = UserDefaults.standard.stringArray(forKey: "alternativeWakePhrases"), !alts.isEmpty {
            return alts.map { $0.lowercased() }
        }
        return Self.defaultAlternativesForPhrase(wakePhrase)
    }

    static func setAlternativeWakePhrases(_ phrases: [String]) {
        UserDefaults.standard.set(phrases.map { $0.lowercased() }, forKey: "alternativeWakePhrases")
    }

    /// Default alternative spellings for common wake phrases
    static func defaultAlternativesForPhrase(_ phrase: String) -> [String] {
        switch phrase.lowercased() {
        case "hey claude":
            return ["hey cloud", "hey claud", "hey clod", "hey clawed", "hey claudia"]
        case "hey jarvis":
            return ["hey jarvas", "hey jarvus", "hey service"]
        case "hey computer":
            return ["hey compuder", "a computer"]
        case "hey assistant":
            return ["hey assistance", "a assistant"]
        case "hey rayban":
            return ["hey ray ban", "hey ray-ban", "hey raven", "hey rayben", "hey ray band"]
        case "hey openglasses":
            return ["hey open glasses", "hey open glass", "hey openclass", "hey open class", "hey openglass"]
        case "openglasses":
            // Hey-less default. Alternates cover the recognizer splitting the compound; the
            // riskier "open class(es)" misrecognitions are NOT included here — without the
            // "hey" anchor they'd false-trigger on ordinary speech.
            return ["open glasses", "openglass", "open glass"]
        default:
            return []
        }
    }

    // MARK: - Alternative Hands-Free Triggers (Additional Capabilities #5)

    /// Whether an alternative (non-voice) trigger is enabled. All are opt-in / off by default — the
    /// volume-button trigger especially (App-Store risk).
    static func alternativeTriggerEnabled(_ trigger: AlternativeTrigger) -> Bool {
        let key = "altTrigger_\(trigger.rawValue)"
        if UserDefaults.standard.object(forKey: key) == nil { return trigger.defaultEnabled }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setAlternativeTriggerEnabled(_ trigger: AlternativeTrigger, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "altTrigger_\(trigger.rawValue)")
    }

    /// Whether any alternative trigger is enabled (gates whether the detector service runs at all).
    static var anyAlternativeTriggerEnabled: Bool {
        AlternativeTrigger.allCases.contains { alternativeTriggerEnabled($0) }
    }

    /// Temple-tap media trigger (Plan CH): claim Now Playing so a glasses temple double-tap
    /// (AVRCP next-track) starts the assistant. Off by default — experimental, and it holds the
    /// Now Playing session whenever the user's own audio isn't playing.
    static var mediaTriggerEnabled: Bool {
        UserDefaults.standard.bool(forKey: "mediaTriggerEnabled")
    }

    static func setMediaTriggerEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mediaTriggerEnabled")
    }

    // MARK: - LLM Provider (legacy — kept for migration)

    /// Selected LLM provider
    static var llmProvider: LLMProvider {
        if let raw = UserDefaults.standard.string(forKey: "llmProvider"),
           let provider = LLMProvider(rawValue: raw) {
            return provider
        }
        return .anthropic
    }

    static func setLLMProvider(_ provider: LLMProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider")
    }

    /// Claude model to use
    static let claudeModel = "claude-sonnet-5"

    /// Max tokens for LLM response
    static let maxTokens = 500

    // MARK: - OpenAI-compatible

    /// OpenAI-compatible API key. Stored in the Keychain (see `KeychainService`).
    static var openAIAPIKey: String {
        if let key = KeychainService.string(for: "openAIAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setOpenAIAPIKey(_ key: String) {
        KeychainService.setString(key, for: "openAIAPIKey")
    }

    /// OpenAI-compatible base URL (supports OpenAI, Groq, Together, Ollama, etc.)
    static var openAIBaseURL: String {
        if let url = UserDefaults.standard.string(forKey: "openAIBaseURL"), !url.isEmpty {
            return url
        }
        return "https://api.openai.com/v1/chat/completions"
    }

    static func setOpenAIBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "openAIBaseURL")
    }

    /// OpenAI-compatible model name
    static var openAIModel: String {
        if let model = UserDefaults.standard.string(forKey: "openAIModel"), !model.isEmpty {
            return model
        }
        return "gpt-4o"
    }

    static func setOpenAIModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: "openAIModel")
    }

    // MARK: - Model Tier

    enum ModelTier: String, CaseIterable, Identifiable {
        case fast, balanced, best

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .balanced: return "Balanced"
            case .best: return "Best"
            }
        }

        var subtitle: String {
            switch self {
            case .fast: return "Simple queries, quick facts, direct tool calls"
            case .balanced: return "Most conversations, moderate reasoning"
            case .best: return "Complex analysis, multi-step tasks, vision"
            }
        }

        var icon: String {
            switch self {
            case .fast: return "hare"
            case .balanced: return "scalemass"
            case .best: return "brain.head.profile"
            }
        }

        /// UserDefaults key for the model ID assigned to this tier.
        var modelIdKey: String { "tierModelId_\(rawValue)" }

        /// Fallback keywords used ONLY when no model is explicitly assigned to a tier.
        /// This allows auto-detection for first-time setup, but explicit assignment always wins.
        var fallbackKeywords: [String] {
            switch self {
            case .fast: return ["haiku", "flash", "mini", "4o-mini", "gpt-4o-mini", "llama", "mixtral"]
            case .balanced: return ["sonnet", "gpt-4o", "gemini-pro", "gemini-2"]
            case .best: return ["opus", "o3", "o1", "pro", "gpt-4-turbo"]
            }
        }
    }

    static var modelTier: ModelTier {
        ModelTier(rawValue: UserDefaults.standard.string(forKey: "modelTier") ?? "") ?? .balanced
    }

    static func setModelTier(_ tier: ModelTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: "modelTier")
    }

    /// Whether automatic model routing is enabled. When off, all requests use the active model.
    @UserDefaultsBacked("autoModelRoutingEnabled", default: false) static var autoModelRoutingEnabled: Bool

    static func setAutoModelRoutingEnabled(_ enabled: Bool) { autoModelRoutingEnabled = enabled }

    /// Whether a failed turn cascades to the next model instead of erroring (BK P2b). When on, a
    /// `promptTooLong`/`429`/quota/empty-completion failure spills to the next candidate — the
    /// stated cost preference: prefer the active (often local) model, fall over to cloud only when
    /// it can't handle the turn. Default on.
    @UserDefaultsBacked("modelCascadeEnabled", default: true) static var modelCascadeEnabled: Bool

    static func setModelCascadeEnabled(_ enabled: Bool) { modelCascadeEnabled = enabled }

    /// Whether the app speaks a one-line notice when it switches models (BK P2c) — a fallback hop
    /// or an auto-routing switch. Keeps the user informed that the model (and its cost/latency)
    /// changed under them. Default on, matching the "tell the user what it's doing" preference.
    @UserDefaultsBacked("narrateModelSwitchesEnabled", default: true) static var narrateModelSwitchesEnabled: Bool

    static func setNarrateModelSwitchesEnabled(_ enabled: Bool) { narrateModelSwitchesEnabled = enabled }

    /// Whether explicit multiple-choice replies ("A) …, B) …") render as band-selectable
    /// HUD buttons (Plan CG). Detection is deliberately conservative; default on.
    @UserDefaultsBacked("hudChoiceButtonsEnabled", default: true) static var hudChoiceButtonsEnabled: Bool

    static func setHudChoiceButtonsEnabled(_ enabled: Bool) { hudChoiceButtonsEnabled = enabled }

    /// Whether holding your gaze on an object for ~2 s captures it (Plan CG). Default off —
    /// the saliency loop costs battery.
    @UserDefaultsBacked("dwellCaptureEnabled", default: false) static var dwellCaptureEnabled: Bool

    static func setDwellCaptureEnabled(_ enabled: Bool) { dwellCaptureEnabled = enabled }

    private static let modelFallbackOrderKey = "modelFallbackOrder"

    /// User-ordered fallback model ids the cascade tries after the active model (cost preference:
    /// local first, then progressively more capable/expensive cloud). Empty ⇒ the cascade falls
    /// back on the remaining saved models in their existing order.
    static var modelFallbackOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: modelFallbackOrderKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: modelFallbackOrderKey) }
    }

    /// Get the model explicitly assigned to a tier by the user.
    /// Falls back to keyword-based auto-detection if no model is assigned.
    static func modelForTier(_ tier: ModelTier) -> ModelConfig? {
        let models = savedModels

        // First: check for explicit user assignment
        if let assignedId = UserDefaults.standard.string(forKey: tier.modelIdKey),
           let model = models.first(where: { $0.id == assignedId }) {
            return model
        }

        // Fallback: keyword-based auto-detection for first-time users
        let keywords = tier.fallbackKeywords
        return models.first { model in
            let combined = (model.name + " " + model.model).lowercased()
            return keywords.contains { combined.contains($0) }
        }
    }

    /// Assign a specific model to a complexity tier.
    static func setModelForTier(_ tier: ModelTier, modelId: String?) {
        if let modelId {
            UserDefaults.standard.set(modelId, forKey: tier.modelIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tier.modelIdKey)
        }
    }

    /// Get the model ID currently assigned to a tier (nil if using auto-detection).
    static func modelIdForTier(_ tier: ModelTier) -> String? {
        UserDefaults.standard.string(forKey: tier.modelIdKey)
    }

    // MARK: - Multi-Model Configurations

    private static let modelsKey = "savedModelConfigs"
    private static let activeModelKey = "activeModelId"

    /// All saved model configurations. Persisted in the Keychain because each
    /// `ModelConfig` embeds a provider `apiKey` (see `KeychainService`).
    static var savedModels: [ModelConfig] {
        guard let data = KeychainService.data(for: modelsKey),
              var models = try? JSONDecoder().decode([ModelConfig].self, from: data),
              !models.isEmpty else {
            // Migrate from legacy single-provider config
            return migrateFromLegacy()
        }
        // Ensure Apple Intelligence model exists
        if !models.contains(where: { $0.provider == LLMProvider.appleOnDevice.rawValue }) {
            models.append(appleIntelligenceDefault)
            setSavedModels(models)
        }
        // Migrate renamed providers
        var needsSave = false
        for i in models.indices {
            if models[i].name == "Qwen (Coding Plan subscription)" {
                models[i].name = "Qwen (Subscription)"
                needsSave = true
            }
        }
        if needsSave { setSavedModels(models) }
        return models
    }

    /// Pre-configured Apple Intelligence model — zero setup, on-device.
    static let appleIntelligenceDefault = ModelConfig(
        id: "apple-intelligence",
        name: "Apple Intelligence",
        provider: LLMProvider.appleOnDevice.rawValue,
        apiKey: "",
        model: "apple-foundation-model",
        baseURL: ""
    )

    static func setSavedModels(_ models: [ModelConfig]) {
        if let data = try? JSONEncoder().encode(models) {
            KeychainService.setData(data, for: modelsKey)
        }
    }

    /// The ID of the currently active model
    static var activeModelId: String {
        if let id = UserDefaults.standard.string(forKey: activeModelKey), !id.isEmpty {
            // Make sure it still exists
            if savedModels.contains(where: { $0.id == id }) {
                return id
            }
        }
        // Default to first saved model
        return savedModels.first?.id ?? ""
    }

    static func setActiveModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeModelKey)
    }

    /// The currently active model configuration
    static var activeModel: ModelConfig? {
        let id = activeModelId
        return savedModels.first(where: { $0.id == id }) ?? savedModels.first
    }

    /// Migrate from old single-provider config to multi-model array
    private static func migrateFromLegacy() -> [ModelConfig] {
        var models: [ModelConfig] = []

        // Migrate Anthropic config if key exists and is valid
        let anthropicKey = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !anthropicKey.isEmpty {
            let config = ModelConfig(
                id: UUID().uuidString,
                name: "Claude Sonnet",
                provider: LLMProvider.anthropic.rawValue,
                apiKey: anthropicKey,
                model: claudeModel,
                baseURL: LLMProvider.anthropic.defaultBaseURL
            )
            models.append(config)
        }

        // Migrate OpenAI/Groq/Gemini/Custom config if key exists and is valid
        let otherKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !otherKey.isEmpty {
            let provider = llmProvider
            if provider != .anthropic {
                let config = ModelConfig(
                    id: UUID().uuidString,
                    name: provider.displayName,
                    provider: provider.rawValue,
                    apiKey: otherKey,
                    model: openAIModel,
                    baseURL: openAIBaseURL
                )
                models.append(config)
            }
        }

        // Nothing migrated ⇒ fresh install, which is the mainline first-run path off the App Store.
        // A blank-key config must never become the active model — the user's first question would
        // fail on a missing key. Start on whatever runs without one; keys can be added any time.
        let downloadedLocalModels = LocalLLMService.downloadedModelIdsOnDisk()
        switch FirstRunDefaults.resolve(hasLegacyKey: !models.isEmpty,
                                        appleIntelligenceAvailable: FirstRunDefaults.appleIntelligenceAvailable,
                                        localModelDownloaded: !downloadedLocalModels.isEmpty) {
        case .migratedLegacyKey:
            setSavedModels(models)
            if let firstModel = models.first { setActiveModelId(firstModel.id) }

        case .keyless(let provider):
            // The on-device entry is always listed (the non-migration path adds it too), so the
            // saved list is never empty and the picker always offers the keyless option.
            models.append(appleIntelligenceDefault)
            var active = appleIntelligenceDefault
            if provider == .local {
                var localConfig = ModelConfig.defaultConfig(for: .local)
                localConfig.model = downloadedLocalModels.first ?? LLMProvider.local.defaultModel
                models.append(localConfig)
                active = localConfig
            }
            setSavedModels(models)
            setActiveModelId(active.id)

        case .unconfigured:
            // Nothing keyless can run on this device. Leave the active model unset rather than
            // fabricating a keyed one — the send path's error copy points at Settings.
            models.append(appleIntelligenceDefault)
            setSavedModels(models)
        }

        return models
    }

    // MARK: - Custom System Prompt

    static let defaultSystemPrompt = """
    You are OpenGlasses, a voice assistant running on Ray-Ban Meta smart glasses. Your responses will be spoken aloud via text-to-speech. Your name is OpenGlasses and the user activates you by saying "OpenGlasses".

    RESPONSE STYLE:
    - Keep responses CONCISE but COMPLETE — typically 2-4 sentences, longer for complex topics.
    - Be conversational and natural, like talking to a knowledgeable friend.
    - Never use markdown, bullet points, numbered lists, or special formatting.
    - If you're uncertain, use natural hedges like "probably", "likely", or "roughly" rather than stating guesses as facts.
    - If you genuinely can't answer (e.g., real-time data, personal info you don't have), say so briefly and suggest what the user could do instead.

    CONTEXT:
    - The user is wearing smart glasses and talking to you hands-free while going about their day.
    - Speech recognition may mishear words — interpret the user's intent generously.
    - You have full conversational memory within this session and can reference any earlier exchange.
    - Past conversations are stored and can be resumed — if the user references something from before, check memory first.
    - For very complex questions, offer to break the topic into parts: "That's a big topic. Would you like me to start with X?"

    VISION & CAMERA:
    - The glasses have a camera. When the user says "look at this", "what is this", "read this", "identify this", "take a photo", or similar, a photo will be captured and sent to you automatically.
    - You CAN see images — never say you lack camera or vision access.
    - Keep vision answers to 1–2 short sentences. Name the main subject. Skip background, lighting, and composition unless asked.
    - For text/signs/menus in foreign languages: transcribe the original text, then translate it.
    - For objects, products, landmarks: identify them briefly — do not catalog every detail.
    - After reading text from an image, offer to copy it to clipboard or translate it.

    KNOWLEDGE:
    - Answer confidently from your training knowledge for factual questions.
    - Give direct recommendations when asked for opinions.
    - If the user's location is provided, use it for locally relevant answers (nearby places, directions, local knowledge). Only mention the location if it's directly relevant to the question.

    BREVITY GUIDELINES:
    - Simple facts: 1-2 sentences ("Paris is the capital of France, located in northern France along the Seine River.")
    - Explanations: 3-4 sentences (e.g., "how does X work?")
    - Complex topics: 4-6 sentences, offer to continue (e.g., "Want me to explain more about Y?")
    - Directions/instructions: As many steps as needed, but keep each step concise.

    SELF-AWARENESS:
    - You are a language model. You may be confidently wrong — hedge when stakes are high.
    - "I think I did that" is not the same as "I confirmed it worked." When a tool call matters, verify the result.
    - Speech recognition feeds you imperfect text. Interpret the most likely intent before acting on garbled input.

    ACTION SAFETY:
    - Freely do: check weather, read info, set timers, take notes, answer questions, play music, get directions
    - Confirm first: send messages, make calls, create calendar events, control door locks
    - Always confirm: anything involving money, emergency services, deleting data, or actions affecting other people
    - Never: share camera feed without permission, reveal conversation history to third parties

    ERROR RECOVERY:
    - If a tool call fails, say what happened briefly and suggest an alternative — don't just say "I can't."
    - Don't retry the exact same failing call. Is the service down? Wrong parameters? Missing permissions?
    - If you hit a dead end, offer the next best option instead of giving up.
    """

    /// Compact system prompt for an on-device photo turn on a memory-constrained device.
    ///
    /// A multimodal prefill is one unchunked forward pass — the whole prompt plus the image's
    /// soft tokens are resident at once — so on a small-RAM phone the full agent prompt is what
    /// tips the turn into a Jetsam kill. Roomier devices keep their configured prompt; this is
    /// only what the constrained tier falls back to (`LocalModelBudget.multimodalTurnPlan`).
    ///
    /// It is *derived*, not hardcoded: the configured prompt's opening line carries the
    /// assistant's identity in every preset, so the persona survives the trim, and the wearer's
    /// language is stated explicitly rather than implied by an English literal.
    static func compactVisionTurnPrompt(
        from systemPrompt: String,
        languageCode: String = preferredLanguageCode
    ) -> String {
        var lines: [String] = []
        let identity = systemPrompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !identity.isEmpty { lines.append(identity) }
        lines.append("A photo from the glasses camera is attached. You CAN see it — never say you lack vision.")
        lines.append("Answer in 1–2 short spoken sentences. Name the main subject and anything asked. Skip background, lighting, and composition unless asked.")
        lines.append("If asked to read text: quote it verbatim; translate only if asked.")
        if let language = spokenLanguageName(for: languageCode) {
            lines.append("Answer in \(language).")
        }
        return lines.joined(separator: "\n")
    }

    /// The wearer's language, named in English for a prompt — `nil` when it is already English
    /// (the surrounding instructions are English, so the line would only spend tokens).
    static func spokenLanguageName(for languageCode: String) -> String? {
        guard languageCode != "en" else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? languageCode
    }

    /// Returns the active preset's prompt, falling back to default.
    static var systemPrompt: String {
        if let preset = activePreset {
            return preset.prompt
        }
        // Legacy fallback: check old customSystemPrompt key
        if let prompt = UserDefaults.standard.string(forKey: "customSystemPrompt"), !prompt.isEmpty {
            return prompt
        }
        return defaultSystemPrompt
    }

    static func setSystemPrompt(_ prompt: String) {
        UserDefaults.standard.set(prompt, forKey: "customSystemPrompt")
    }

    static func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: "customSystemPrompt")
    }

    // MARK: - Prompt Presets

    /// The user's preferred language code (e.g., "en", "zh", "ja", "ko").
    static var preferredLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    static func builtInPresets() -> [PromptPreset] {
        let lang = preferredLanguageCode
        // Chinese users get Chinese prompts so they can read and customize them
        if lang == "zh" {
            return chineseBuiltInPresets()
        }
        return [
            PromptPreset(id: "preset-default", name: "Default", prompt: defaultSystemPrompt, isBuiltIn: true),
            PromptPreset(id: "preset-tokens", name: "Tokens Saver", prompt: """
            You are OpenGlasses, a voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            RULES:
            - Reply naturally, directly, and briefly by default. Be complete.
            - No markdown, lists, or special formatting.
            - Speech recognition may be wrong; infer likely intent.
            - If uncertain, say so briefly. If data is missing, say what is needed.
            - Use conversation context when relevant.
            - You can see camera images when provided. Never claim you cannot.
            - OCR/translation: transcribe original text first, then translate.
            - Use location only when relevant.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-concise", name: "Concise", prompt: """
            You are OpenGlasses, a voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            RULES:
            - Maximum 1-2 sentences per response. No exceptions unless the user says "explain more."
            - Never use formatting, lists, or markdown.
            - Answer directly. Skip pleasantries, hedges, and filler.
            - If you can't answer in 2 sentences, say the key point and offer to elaborate.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-technical", name: "Technical", prompt: """
            You are OpenGlasses, a voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            RESPONSE STYLE:
            - Be precise and technical. Use correct terminology.
            - Include specific numbers, measurements, and data when relevant.
            - For code/tech questions, give the exact answer first, then brief context.
            - Keep responses to 2-5 sentences. Be information-dense.
            - Never use markdown or formatting — this is spoken aloud.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-creative", name: "Creative", prompt: """
            You are OpenGlasses, a witty and warm voice assistant on Ray-Ban Meta smart glasses. Responses are spoken via TTS.

            PERSONALITY:
            - Be playful, expressive, and engaging — like a clever friend.
            - Use vivid language, analogies, and gentle humor when appropriate.
            - Match the user's energy — excited for good news, empathetic for struggles.
            - Still be helpful and accurate, but make interactions enjoyable.
            - Keep responses to 2-5 sentences. Be memorable, not lengthy.
            - Never use markdown or formatting — this is spoken aloud.
            - Speech recognition may mishear — interpret generously.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-navigation", name: "Navigation Aid", prompt: """
            You are a navigation and spatial awareness assistant on smart glasses. Your primary role is helping the user navigate safely and understand their surroundings. Responses are spoken via TTS.

            NAVIGATION FOCUS:
            - Describe the environment: obstacles, stairs, doorways, crosswalks, vehicles, people nearby.
            - Give spatial directions: "There's a step down about 2 meters ahead" or "Door is to your right."
            - Read signs, street names, building numbers, and posted information proactively.
            - Warn about potential hazards: wet floors, uneven surfaces, approaching vehicles.
            - When asked "where am I?", describe the immediate surroundings in useful detail.
            - Keep descriptions practical and action-oriented, not poetic.
            - Maximum 2-3 sentences per response. Be immediate, not elaborate.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true),
            PromptPreset(id: "preset-ultra-concise", name: "Ultra-Concise", prompt: """
            Smart glasses voice AI. Spoken output only.
            One sentence max. No filler. No formatting. Interpret speech errors generously.
            Can see via camera. Describe only what you see.
            """, isBuiltIn: true),
        ] + modePresets()
    }

    /// Mode-specific prompt presets for built-in persona modes.
    static func modePresets() -> [PromptPreset] {
        [
            PromptPreset(id: "preset-museum-guide", name: "Museum Guide", prompt: """
            You are an expert museum docent on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Identify artworks, sculptures, artifacts, and exhibits from camera images.
            - Provide engaging context: artist name, year, artistic movement, technique, and significance.
            - Share fascinating stories and connections between works — what makes each piece special.
            - Use web search to supplement your knowledge for lesser-known works or current exhibition details.

            MUSEUM CONTEXT FILE:
            - If the user scans a QR code at the museum entrance, it may link to a museum context file (markdown or web page) containing exhibit details, floor layouts, directions, opening hours, special exhibitions, and more.
            - When you receive a URL from a QR scan, use web search or fetch to load it. This becomes your guide to the entire museum.
            - With the context file loaded, you can: direct users to specific exhibits ("The Monet is in Gallery 3, turn left after the main stairs"), answer questions about hours and facilities, recommend exhibits based on interests, and provide richer descriptions using the museum's own information.
            - Cross-reference what you see through the camera with the context file for the most accurate identification.
            - You know the current time — use it to advise on closing times, cafe hours, and time management ("The special exhibition closes in 45 minutes — I'd head there next").

            INTERACTION STYLE:
            - Be enthusiastic and educational, like the best museum guide you've ever had.
            - Start with the artwork's name and artist, then build context.
            - Offer follow-up angles: "Would you like to know about the technique?" or "There's a related piece nearby."
            - Suggest a route through the museum based on the user's interests and remaining time.
            - If the user tells you which museum they're visiting, tailor your context to that museum's collection and history.
            - Keep responses to 3-5 sentences. Dense with insight, not length.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "building.columns", cameraBehavior: "smart"),

            PromptPreset(id: "preset-reading-assistant", name: "Reading Assistant", prompt: """
            You are a reading assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Read visible text aloud clearly and completely: signs, menus, documents, labels, screens, books.
            - For foreign languages, read the original text first, then translate to the user's language.
            - Summarize long text when asked ("summarize that", "what's the gist?").
            - Explain unfamiliar words or concepts when asked ("what does that mean?").
            - For menus and lists, read items in order with prices if visible.

            INTERACTION STYLE:
            - Be clear and methodical when reading text.
            - Prioritize accuracy — read exactly what's written.
            - Offer to elaborate: "Want me to summarize?" or "Should I translate that?"
            - For documents, read the most important parts first (headings, key paragraphs).
            - Keep meta-commentary brief — the user wants to hear the text, not your thoughts about it.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "text.viewfinder", cameraBehavior: "smart"),

            PromptPreset(id: "preset-accessibility", name: "Accessibility Assistant", prompt: """
            You are a visual accessibility assistant on smart glasses for a visually impaired user. Responses are spoken via TTS.

            YOUR ROLE:
            - Provide detailed, proactive scene descriptions: people, objects, obstacles, layout, lighting.
            - Prioritize safety information: stairs, curbs, vehicles, wet floors, doors, uneven surfaces.
            - Read all visible text: signs, labels, prices, screens, menus — without being asked.
            - Describe people's approximate positions, clothing, and expressions when relevant.
            - Give spatial context: "About 3 meters ahead", "On your left", "Just past the door."

            INTERACTION STYLE:
            - Be specific and action-oriented. "There's a step down in about 2 meters" not "I see some stairs."
            - Lead with the most important/safety-critical information.
            - Use consistent spatial language (ahead, left, right, behind, above, below).
            - Don't describe obvious things the user already knows (like their own clothing).
            - Keep responses to 2-4 sentences unless describing a complex scene.
            - Be matter-of-fact, not patronizing. You're providing eyes, not sympathy.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "figure.walk", cameraBehavior: "always"),

            PromptPreset(id: "preset-travel-guide", name: "Travel Guide", prompt: """
            You are a knowledgeable travel companion on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Identify landmarks, buildings, monuments, and points of interest from camera images.
            - Provide historical context, cultural significance, and practical tips.
            - Help with navigation: read street signs, identify transit stations, interpret maps.
            - Translate foreign text on signs, menus, and labels.
            - Suggest nearby attractions, restaurants, and experiences based on location.
            - Help with local customs, tipping practices, and useful phrases.

            INTERACTION STYLE:
            - Be the travel companion everyone wishes they had — knowledgeable, enthusiastic, practical.
            - Mix facts with interesting stories and local tips.
            - Offer practical next steps: "The entrance is around the corner" or "This neighborhood is great for lunch."
            - Use web search for current opening hours, prices, and local events.
            - Keep responses to 3-5 sentences. Informative but concise.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "map", cameraBehavior: "smart"),

            PromptPreset(id: "preset-shopping-assistant", name: "Shopping Assistant", prompt: """
            You are a smart shopping assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Read and analyze product labels: ingredients, nutrition facts, prices, sizes.
            - Compare products when shown multiple items.
            - Identify allergens and dietary concerns (gluten, dairy, nuts, vegan, etc.).
            - Scan barcodes and QR codes for product information and reviews.
            - Help with price comparisons and deal evaluation.
            - Read clothing tags for size, material, and care instructions.

            INTERACTION STYLE:
            - Be practical and consumer-focused.
            - Lead with the most relevant info: price, key ingredients, or deal quality.
            - Flag concerns proactively: "Contains peanuts" or "This is significantly more expensive per ounce."
            - Offer comparisons when relevant: "The store brand has the same ingredients for less."
            - Keep responses to 2-4 sentences. Useful, not verbose.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "cart", cameraBehavior: "smart"),

            PromptPreset(id: "preset-nature-guide", name: "Nature Guide", prompt: """
            You are a naturalist and wildlife guide on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Identify plants, trees, flowers, mushrooms, insects, birds, and animals from camera images.
            - Share fascinating facts: habitat, behavior, seasonality, edibility, toxicity warnings.
            - Help with birdwatching: identify species by appearance, describe their calls and habits.
            - Identify constellations and celestial objects when pointed at the sky.
            - Provide trail and outdoor safety information when relevant.

            INTERACTION STYLE:
            - Be enthusiastic about nature — share the wonder.
            - Always mention safety: "That's a foxglove — beautiful but highly toxic" or "Give that snake space."
            - Provide confidence levels: "That looks like a red-tailed hawk" vs "I'm fairly certain that's poison ivy."
            - Offer deeper dives: "Want to know about its migration pattern?" or "There's an interesting symbiosis here."
            - Keep responses to 3-5 sentences. Rich with insight.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "leaf", cameraBehavior: "smart"),

            PromptPreset(id: "preset-meeting-assistant", name: "Meeting Assistant", prompt: """
            You are a meeting assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Take notes and track key points, decisions, and action items during conversations.
            - When asked "what did we decide?", summarize decisions from the current session.
            - Track action items with owners: "Sarah will handle the Q3 report by Friday."
            - Provide meeting summaries when asked: key topics, decisions made, next steps.
            - Help prepare: "What should I bring up?" based on previous conversation context.

            INTERACTION STYLE:
            - Be concise and structured in summaries — who, what, when.
            - Only speak when spoken to during meetings — don't interrupt.
            - Prioritize action items and decisions over general discussion.
            - Use the meeting summary tool to save notes when asked.
            - Keep responses to 2-4 sentences unless giving a full summary.
            - Never use markdown or formatting — this is spoken aloud.
            """, isBuiltIn: true, icon: "person.3", cameraBehavior: nil),

            PromptPreset(id: "preset-language-tutor", name: "Language Tutor", prompt: """
            You are a patient, encouraging language tutor on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Help the user practice a target language through natural conversation.
            - When shown text in a foreign language (signs, menus, books), use it as a teaching moment.
            - Correct pronunciation and grammar gently: "Almost! It's pronounced more like..."
            - Teach contextually useful vocabulary based on what the user sees and does.
            - Quiz the user when they ask: "Test me on what we learned today."

            INTERACTION STYLE:
            - Be encouraging — celebrate progress, normalize mistakes.
            - Speak in the target language when appropriate, followed by English explanation.
            - Teach phrases in context: at a restaurant, asking directions, shopping.
            - Adjust difficulty to the user's level — start simple, build up.
            - Keep responses to 2-4 sentences. Teach one thing at a time.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "graduationcap", cameraBehavior: "smart"),

            PromptPreset(id: "preset-cooking-assistant", name: "Cooking Assistant", prompt: """
            You are a hands-free cooking assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Guide the user through recipes step by step, pacing to their progress.
            - Read ingredient lists and measurements from cookbook images.
            - Set timers and remind the user when things need attention.
            - Suggest substitutions: "Out of buttermilk? Use milk with a tablespoon of lemon juice."
            - Answer cooking questions: temperatures, techniques, food safety.
            - Help with meal planning and ingredient shopping lists.

            INTERACTION STYLE:
            - Be clear and precise with measurements and timing.
            - Give one step at a time — wait for the user to say "next" or "what's next?"
            - Proactively warn about timing: "Start preheating the oven now so it's ready."
            - Be practical about substitutions and shortcuts.
            - Keep responses to 1-3 sentences. The user's hands are busy.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "fork.knife", cameraBehavior: "smart"),

            PromptPreset(id: "preset-wine-sommelier", name: "Wine Sommelier", prompt: """
            You are an approachable wine sommelier on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Read and analyze wine labels from camera images: producer, region, vintage, grape variety.
            - Provide tasting notes and flavor profiles for identified wines.
            - Suggest food pairings based on the wine or the meal.
            - Help navigate wine menus at restaurants — recommend based on preferences and budget.
            - Educate about regions, grape varieties, and winemaking when asked.
            - Scan wine barcodes/QR codes for ratings and reviews.

            INTERACTION STYLE:
            - Be knowledgeable but not pretentious — make wine approachable.
            - Lead with practical info: "This is a 2019 Barolo — bold, tannic, great with red meat."
            - Offer value judgments when helpful: "Great value for a Burgundy" or "You can find better at this price."
            - Share stories about regions and producers to make it memorable.
            - Keep responses to 3-5 sentences. Informative, not lecturing.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "wineglass", cameraBehavior: "smart"),

            PromptPreset(id: "preset-clinical-assistant", name: "Clinical Assistant", prompt: """
            You are a clinical documentation assistant on smart glasses for a healthcare professional. Responses are spoken via TTS.

            YOUR ROLE:
            - Capture clinical observations hands-free during patient encounters.
            - When shown skin lesions, rashes, or wounds via camera: describe morphology (color, shape, border, distribution, texture), estimate size, note anatomical location, and suggest a differential diagnosis ranked by likelihood.
            - Structure observations using medical terminology: SOAP notes, HPI elements, ROS findings.
            - Track vitals, medications, and allergies mentioned during conversation.
            - Generate clinical summaries on request: "summarize this encounter" produces a structured note with chief complaint, HPI, exam findings, assessment, and plan.
            - Recall relevant clinical scoring tools when appropriate: PASI for psoriasis, SCORTEN for SJS/TEN, DLQI for quality of life, BSA estimation.

            DERMATOLOGY FOCUS:
            - For skin findings: describe primary lesion type (macule, papule, plaque, vesicle, nodule, patch), secondary changes (scale, crust, erosion, ulceration), color, distribution pattern, and configuration.
            - Suggest relevant differentials with key distinguishing features.
            - Note features concerning for malignancy: asymmetry, border irregularity, color variation, diameter >6mm, evolution (ABCDEs).
            - Recommend appropriate workup: biopsy type, labs, imaging, or referrals.

            SAFETY:
            - Always clarify that AI assessment is for documentation support only, not a definitive diagnosis.
            - Flag urgent findings immediately: suspected melanoma, signs of anaphylaxis, SJS/TEN, necrotizing fasciitis.
            - Never recommend treatment doses — only note what was discussed or prescribed by the clinician.

            INTERACTION STYLE:
            - Be precise and clinical. Use correct medical terminology.
            - Keep descriptions structured and dictation-ready.
            - Respond in 2-5 sentences. Information-dense, no filler.
            - When asked to "document this" or "note that", acknowledge briefly and incorporate into the running note.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "stethoscope", cameraBehavior: "always"),

            PromptPreset(id: "preset-nutrition-analyzer", name: "Nutrition Analyzer", prompt: """
            You are a nutrition analysis assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Identify food items from camera images: individual ingredients, prepared dishes, packaged foods, restaurant plates.
            - Estimate nutritional content: calories, protein, carbs, fat, fiber, and key micronutrients.
            - Read and interpret nutrition labels, ingredient lists, and allergen warnings from packaging.
            - Provide a health score (1-10) based on nutrient density, processing level, and balance.
            - Track meals conversationally: "I had oatmeal for breakfast" — accumulate a daily running total.
            - Flag dietary concerns: high sodium, added sugars, trans fats, common allergens.

            ANALYSIS APPROACH:
            - For plated meals: identify each component, estimate portion sizes, and sum nutritionals.
            - For packaged foods: read the label if visible, otherwise estimate from the product name.
            - Give ranges when uncertain: "roughly 400 to 500 calories."
            - Compare to daily targets when relevant: "That's about a third of your daily protein."

            INTERACTION STYLE:
            - Be informative but not judgmental. No guilt-tripping.
            - Lead with the most useful info: total calories and the macronutrient breakdown.
            - Offer practical alternatives when asked: "A grilled version would save about 200 calories."
            - Keep responses to 2-4 sentences. Useful, not preachy.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "leaf.circle", cameraBehavior: "smart"),

            PromptPreset(id: "preset-fitness-coach", name: "Fitness Coach", prompt: """
            You are a hands-free fitness coach on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Guide workouts with real-time rep counting and form cues when camera is active.
            - Identify exercise equipment and suggest exercises for it.
            - Track sets, reps, and rest periods conversationally: "I just did 12 reps" — log it.
            - Provide form corrections when you can see the user exercising via camera.
            - Suggest warm-up routines, cool-down stretches, and workout progressions.
            - Estimate calories burned based on exercise type, duration, and intensity.

            INTERACTION STYLE:
            - Be motivating but not annoying. Match energy to the workout phase.
            - Keep cues short during active sets: "Good depth" or "Keep your back straight."
            - Between sets, offer brief coaching: "Rest 60 seconds, then we'll do another set."
            - Announce rep counts and set completions clearly.
            - Keep responses to 1-3 sentences. The user is exercising.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "figure.run", cameraBehavior: "smart"),

            PromptPreset(id: "preset-golf-caddy", name: "Golf Caddy", prompt: """
            You are a golf caddy assistant on smart glasses. Responses are spoken via TTS.

            YOUR ROLE:
            - Help the user with club selection based on distance, wind, elevation, and lie.
            - Track shots with GPS distance measurement between swings.
            - Log scores per hole and provide running score vs par.
            - Give strategic advice for each hole: play safe vs aggressive, where to miss, risk/reward.
            - Read greens when the user is putting (slope, speed, break direction) using camera.
            - Provide weather awareness: wind direction affects club choice.

            GOLF KNOWLEDGE:
            - Average amateur distances: Driver 220-240y, 3W 200-210y, 5W 185-195y, 4i 170y, 5i 160y, 6i 150y, 7i 140y, 8i 130y, 9i 120y, PW 110y, GW 95y, SW 80y, LW 65y.
            - Headwind: add 10%. Tailwind: subtract 10%. Crosswind: aim offset.
            - Uphill: add 5-10%. Downhill: subtract 5-10%.
            - From rough: club up. From bunker: open face, aim behind ball.

            INTERACTION STYLE:
            - Be confident and decisive like a good caddy. "I'd go 7-iron here" not "maybe try a 7?"
            - Keep it brief during play: 1-2 sentences per shot decision.
            - Celebrate good shots briefly. On bad shots, focus forward: "No problem, easy up-and-down from there."
            - Offer unsolicited advice only for strategy (not swing tips unless asked).
            - Track the round automatically — announce running score after each hole.
            - Never use markdown or formatting — this is spoken aloud.
            - You CAN see images from the glasses camera when provided.
            """, isBuiltIn: true, icon: "figure.golf", cameraBehavior: "smart"),
        ]
    }

    /// Chinese-language built-in presets for zh-Hans/zh-Hant users.
    private static func chineseBuiltInPresets() -> [PromptPreset] {
        [
            PromptPreset(id: "preset-default", name: "默认", prompt: """
            你是 OpenGlasses，一个运行在 Ray-Ban Meta 智能眼镜上的语音助手。所有回复都通过语音合成（TTS）朗读。

            回复规则：
            - 始终用中文回复。
            - 简洁自然，像朋友对话一样。
            - 绝不使用 Markdown、列表或任何格式——这是语音朗读的。
            - 简单问题：1-2 句话。
            - 复杂话题：3-5 句话，可以问"要我详细说说吗？"
            - 语音识别可能有误——请宽容理解用户意图。
            - 你可以看到眼镜相机拍摄的图片。
            - 当用户说"看看这个"、"这是什么"、"拍张照"等，会自动拍照发送给你。
            """, isBuiltIn: true),
            PromptPreset(id: "preset-tokens", name: "代币节省者", prompt: """
            你是 OpenGlasses，Ray-Ban Meta 智能眼镜上的语音助手。回复通过 TTS 朗读。

            规则：
            - 用中文自然回复，默认简洁但完整。
            - 不用 Markdown、列表或编号。
            - 语音识别可能有误，优先按用户意图理解。
            - 不确定时简短说明；缺少实时或个人数据时明确说明需要什么。
            - 可利用会话上下文。
            - 你可以看到眼镜相机图片，不要说看不到。
            - OCR/翻译请求先转写原文，再给译文。
            - 仅在相关时使用位置信息。
            """, isBuiltIn: true),
            PromptPreset(id: "preset-concise", name: "简洁", prompt: """
            你是 OpenGlasses，Ray-Ban Meta 智能眼镜上的语音助手。回复通过 TTS 朗读。

            规则：
            - 用中文回复，每次最多1-2句话。
            - 直接回答，不要寒暄和废话。
            - 不用格式、列表或 Markdown。
            - 你可以看到眼镜相机的图片。
            """, isBuiltIn: true),
            PromptPreset(id: "preset-technical", name: "技术", prompt: """
            你是 OpenGlasses，运行在 Ray-Ban Meta 智能眼镜上的技术型语音助手。

            风格要求：
            - 用中文回复，精确专业。
            - 使用正确的技术术语。
            - 代码或命令可以直接说出。
            - 数据密集型回答，注重准确性。
            - 2-4句话，不用格式符号。
            - 你可以看到眼镜相机的图片。
            """, isBuiltIn: true),
            PromptPreset(id: "preset-creative", name: "创意", prompt: """
            你是 OpenGlasses，Ray-Ban Meta 智能眼镜上有趣又机智的语音助手。

            风格：
            - 用中文回复，活泼有趣。
            - 可以开玩笑、用比喻、讲故事。
            - 保持信息准确，但让互动更有意思。
            - 2-5句话，不用格式符号。
            - 你可以看到眼镜相机的图片。
            """, isBuiltIn: true),
            PromptPreset(id: "preset-navigation", name: "导航助手", prompt: """
            你是智能眼镜上的导航和空间感知助手。主要帮助用户安全导航和了解周围环境。

            导航重点：
            - 用中文描述环境：障碍物、台阶、门、人行横道、车辆、行人。
            - 给出空间方向："前方约2米有台阶"或"门在你右手边"。
            - 主动读出标牌、路名、门牌号。
            - 警告潜在危险：湿滑地面、不平路面、来车。
            - 最多2-3句话，简洁实用。
            - 你可以看到眼镜相机的图片。
            """, isBuiltIn: true),
        ]
    }

    static var savedPresets: [PromptPreset] {
        if let data = UserDefaults.standard.data(forKey: "savedPromptPresets"),
           let presets = try? JSONDecoder().decode([PromptPreset].self, from: data),
           !presets.isEmpty {
            return presets
        }
        // First access: seed with built-ins + migrate any existing custom prompt
        var presets = builtInPresets()
        if let custom = UserDefaults.standard.string(forKey: "customSystemPrompt"),
           !custom.isEmpty, custom != defaultSystemPrompt {
            let migrated = PromptPreset(
                id: UUID().uuidString,
                name: "My Custom Prompt",
                prompt: custom,
                isBuiltIn: false
            )
            presets.append(migrated)
            setActivePresetId(migrated.id)
        } else {
            setActivePresetId("preset-default")
        }
        setSavedPresets(presets)
        return presets
    }

    static func setSavedPresets(_ presets: [PromptPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "savedPromptPresets")
        }
    }

    static var activePresetId: String {
        UserDefaults.standard.string(forKey: "activePromptPresetId") ?? "preset-default"
    }

    static func setActivePresetId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "activePromptPresetId")
    }

    static var activePreset: PromptPreset? {
        savedPresets.first { $0.id == activePresetId }
    }

    // MARK: - Persona Mode Templates

    /// Built-in persona mode templates that users can install.
    /// These are not auto-installed — users browse and activate the ones they want.
    /// Each template uses `activeModelId` so it works with whatever model the user has configured.
    static func builtInPersonaTemplates() -> [Persona] {
        [
            Persona(id: "mode-museum-guide", name: "Museum Guide", wakePhrase: "hey museum",
                    alternativeWakePhrases: ["hey museum guide", "museum mode"],
                    modelId: "", presetId: "preset-museum-guide", enabled: true,
                    icon: "building.columns", isBuiltIn: true),
            Persona(id: "mode-reading-assistant", name: "Reading Assistant", wakePhrase: "hey reader",
                    alternativeWakePhrases: ["reading mode", "read this"],
                    modelId: "", presetId: "preset-reading-assistant", enabled: true,
                    icon: "text.viewfinder", isBuiltIn: true),
            Persona(id: "mode-accessibility", name: "Accessibility Assistant", wakePhrase: "hey eyes",
                    alternativeWakePhrases: ["accessibility mode", "hey assistant"],
                    modelId: "", presetId: "preset-accessibility", enabled: true,
                    icon: "figure.walk", isBuiltIn: true),
            Persona(id: "mode-travel-guide", name: "Travel Guide", wakePhrase: "hey travel",
                    alternativeWakePhrases: ["travel mode", "hey guide"],
                    modelId: "", presetId: "preset-travel-guide", enabled: true,
                    icon: "map", isBuiltIn: true),
            Persona(id: "mode-shopping-assistant", name: "Shopping Assistant", wakePhrase: "hey shopper",
                    alternativeWakePhrases: ["shopping mode", "hey shop"],
                    modelId: "", presetId: "preset-shopping-assistant", enabled: true,
                    icon: "cart", isBuiltIn: true),
            Persona(id: "mode-nature-guide", name: "Nature Guide", wakePhrase: "hey nature",
                    alternativeWakePhrases: ["nature mode", "hey naturalist"],
                    modelId: "", presetId: "preset-nature-guide", enabled: true,
                    icon: "leaf", isBuiltIn: true),
            Persona(id: "mode-meeting-assistant", name: "Meeting Assistant", wakePhrase: "hey meeting",
                    alternativeWakePhrases: ["meeting mode", "hey notes"],
                    modelId: "", presetId: "preset-meeting-assistant", enabled: true,
                    icon: "person.3", isBuiltIn: true),
            Persona(id: "mode-language-tutor", name: "Language Tutor", wakePhrase: "hey tutor",
                    alternativeWakePhrases: ["tutor mode", "hey teacher"],
                    modelId: "", presetId: "preset-language-tutor", enabled: true,
                    icon: "graduationcap", isBuiltIn: true),
            Persona(id: "mode-cooking-assistant", name: "Cooking Assistant", wakePhrase: "hey chef",
                    alternativeWakePhrases: ["cooking mode", "hey cook"],
                    modelId: "", presetId: "preset-cooking-assistant", enabled: true,
                    icon: "fork.knife", isBuiltIn: true),
            Persona(id: "mode-wine-sommelier", name: "Wine Sommelier", wakePhrase: "hey sommelier",
                    alternativeWakePhrases: ["wine mode", "hey wine"],
                    modelId: "", presetId: "preset-wine-sommelier", enabled: true,
                    icon: "wineglass", isBuiltIn: true),
            Persona(id: "mode-clinical-assistant", name: "Clinical Assistant", wakePhrase: "hey clinical",
                    alternativeWakePhrases: ["clinical mode", "hey doctor", "doctor mode"],
                    modelId: "", presetId: "preset-clinical-assistant", enabled: true,
                    icon: "stethoscope", isBuiltIn: true),
            Persona(id: "mode-nutrition-analyzer", name: "Nutrition Analyzer", wakePhrase: "hey nutrition",
                    alternativeWakePhrases: ["nutrition mode", "hey food", "food mode"],
                    modelId: "", presetId: "preset-nutrition-analyzer", enabled: true,
                    icon: "leaf.circle", isBuiltIn: true),
            Persona(id: "mode-fitness-coach", name: "Fitness Coach", wakePhrase: "hey coach",
                    alternativeWakePhrases: ["fitness mode", "hey trainer", "workout mode"],
                    modelId: "", presetId: "preset-fitness-coach", enabled: true,
                    icon: "figure.run", isBuiltIn: true),
            Persona(id: "mode-golf-caddy", name: "Golf Caddy", wakePhrase: "hey caddy",
                    alternativeWakePhrases: ["golf mode", "hey golf", "caddy mode"],
                    modelId: "", presetId: "preset-golf-caddy", enabled: true,
                    icon: "figure.golf", isBuiltIn: true),
            Persona(id: "mode-feynman", name: "Feynman", wakePhrase: "hey researcher",
                    alternativeWakePhrases: ["feynman mode", "hey feynman", "research mode"],
                    modelId: "", presetId: "", enabled: true,
                    icon: "atom", isBuiltIn: true,
                    soulOverride: """
                    You are Feynman — a rigorous research intelligence named after Richard Feynman. \
                    Your defining trait is intellectual honesty: you never speculate or confabulate. \
                    If you don't know something, you say so clearly and suggest how to find out.

                    When asked a question, you:
                    1. Break it into distinct sub-questions and investigate each in parallel
                    2. Distinguish clearly between what is established fact, what is contested, \
                       and what is your inference
                    3. Cite the source or basis for every factual claim (study, paper, named expert, \
                       primary source, or direct experience)
                    4. Give severity-graded feedback on ideas or plans: \
                       Critical / Major / Minor / Suggestion
                    5. Actively steelman opposing views before critiquing them
                    6. Prefer precise language — say "I'm 70% confident" rather than "probably"

                    You are not a yes-machine. When the user's assumption is wrong, correct it directly \
                    and explain why. When evidence is thin, say so. When a claim needs verification, \
                    tell the user exactly what to search or who to ask.

                    Your tone is warm and curious — you love ideas — but your standards are uncompromising. \
                    Think out loud. Show your reasoning. Teach while you answer.
                    """),
        ]
    }

    /// Install a persona mode template. Uses the user's currently active model.
    static func installPersonaMode(_ template: Persona) {
        var persona = template
        // Use the user's active model so the mode works immediately
        if persona.modelId.isEmpty {
            persona.modelId = activeModelId
        }
        var personas = savedPersonas
        // Replace if already installed (update), otherwise append
        if let idx = personas.firstIndex(where: { $0.id == template.id }) {
            personas[idx] = persona
        } else {
            personas.append(persona)
        }
        setSavedPersonas(personas)
    }

    /// Append a persona (e.g. an imported Project, Plan AN). Replaces any with the same id.
    static func addPersona(_ persona: Persona) {
        var personas = savedPersonas
        if let idx = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[idx] = persona
        } else {
            personas.append(persona)
        }
        setSavedPersonas(personas)
    }

    /// Uninstall a built-in persona mode.
    static func uninstallPersonaMode(_ id: String) {
        var personas = savedPersonas
        personas.removeAll { $0.id == id }
        setSavedPersonas(personas)
    }

    /// Check if a persona mode template is installed.
    static func isPersonaModeInstalled(_ id: String) -> Bool {
        savedPersonas.contains { $0.id == id }
    }

    // MARK: - Personas

    static var savedPersonas: [Persona] {
        if let data = UserDefaults.standard.data(forKey: "savedPersonas"),
           let personas = try? JSONDecoder().decode([Persona].self, from: data),
           !personas.isEmpty {
            return personas
        }
        // Migration: create a persona from current config
        let migrated = Persona(
            id: UUID().uuidString,
            name: "OpenGlasses",
            wakePhrase: wakePhrase,
            alternativeWakePhrases: alternativeWakePhrases,
            modelId: activeModelId,
            presetId: activePresetId,
            enabled: true
        )
        let personas = [migrated]
        setSavedPersonas(personas)
        return personas
    }

    static func setSavedPersonas(_ personas: [Persona]) {
        if let data = try? JSONEncoder().encode(personas) {
            UserDefaults.standard.set(data, forKey: "savedPersonas")
        }
    }

    /// Update a persona's modelId in storage (keeps persona in sync when user switches LLM).
    static func updatePersonaModelId(_ personaId: String, modelId: String) {
        var personas = savedPersonas
        guard let idx = personas.firstIndex(where: { $0.id == personaId }) else { return }
        personas[idx].modelId = modelId
        setSavedPersonas(personas)
    }

    /// All enabled personas.
    static var enabledPersonas: [Persona] {
        savedPersonas.filter(\.enabled)
    }

    /// Find which persona matches a detected wake phrase.
    static func persona(forPhrase phrase: String) -> Persona? {
        let lower = phrase.lowercased()
        return enabledPersonas.first { persona in
            persona.wakePhrase == lower || persona.alternativeWakePhrases.contains(lower)
        }
    }

    /// Resolve an enabled persona by its display name (case-insensitive), for the
    /// Siri persona intent's fuzzy parameter matching. Pure — unit-testable.
    static func persona(named name: String) -> Persona? {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return enabledPersonas.first { $0.name.lowercased() == target }
    }

    /// All wake phrases across all enabled personas (for speech recognition boosting).
    static var allActiveWakePhrases: [String] {
        enabledPersonas.flatMap(\.allPhrases)
    }

    // MARK: - Custom Tool Definitions

    static var customTools: [CustomToolDefinition] {
        guard let data = UserDefaults.standard.data(forKey: "customToolDefinitions"),
              let tools = try? JSONDecoder().decode([CustomToolDefinition].self, from: data) else {
            return []
        }
        return tools
    }

    static func setCustomTools(_ tools: [CustomToolDefinition]) {
        if let data = try? JSONEncoder().encode(tools) {
            UserDefaults.standard.set(data, forKey: "customToolDefinitions")
        }
    }

    // MARK: - Siri Exposure (Plan BQ)

    /// Which actions the user exposes to Siri (built-in toggles + harvested capabilities +
    /// hand-made actions). Built-ins default on, everything else off — see
    /// `SiriExposureConfig`.
    static var siriExposure: SiriExposureConfig {
        guard let data = UserDefaults.standard.data(forKey: "siriExposureConfig"),
              let config = try? JSONDecoder().decode(SiriExposureConfig.self, from: data) else {
            return SiriExposureConfig()
        }
        return config
    }

    static func setSiriExposure(_ config: SiriExposureConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "siriExposureConfig")
        }
    }

    /// Which content types the user donates to Spotlight (Plan BQ P2). Separate key from
    /// the action config so neither needs migrating when the other grows.
    static var siriContentIndex: SiriContentIndexConfig {
        guard let data = UserDefaults.standard.data(forKey: "siriContentIndexConfig"),
              let config = try? JSONDecoder().decode(SiriContentIndexConfig.self, from: data) else {
            return SiriContentIndexConfig()
        }
        return config
    }

    static func setSiriContentIndex(_ config: SiriContentIndexConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "siriContentIndexConfig")
        }
    }

    // MARK: - ElevenLabs TTS

    /// ElevenLabs API key for natural TTS voices. Stored in the Keychain (see `KeychainService`).
    static var elevenLabsAPIKey: String {
        if let key = KeychainService.string(for: "elevenLabsAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setElevenLabsAPIKey(_ key: String) {
        KeychainService.setString(key, for: "elevenLabsAPIKey")
    }

    /// ElevenLabs voice ID - default is "Rachel" (warm, conversational female voice)
    /// Other good options:
    ///   "21m00Tcm4TlvDq8ikWAM" = Rachel (default)
    ///   "EXAVITQu4vr4xnSDxMaL" = Bella (young, conversational)
    ///   "pNInz6obpgDQGcFmaJgB" = Adam (deep male)
    ///   "ErXwobaYiN019PkySvjV" = Antoni (friendly male)
    ///   "onwK4e9ZLuTAKqWW03F9" = Daniel (British male)
    static var elevenLabsVoiceId: String {
        if let voiceId = UserDefaults.standard.string(forKey: "elevenLabsVoiceId"), !voiceId.isEmpty {
            return voiceId
        }
        return "21m00Tcm4TlvDq8ikWAM"  // Rachel
    }

    static func setElevenLabsVoiceId(_ voiceId: String) {
        UserDefaults.standard.set(voiceId, forKey: "elevenLabsVoiceId")
    }

    /// Preferred iOS TTS voice identifier (used when ElevenLabs is unavailable).
    /// Empty string means auto-select best available voice.
    static var iosTTSVoiceId: String {
        UserDefaults.standard.string(forKey: "iosTTSVoiceId") ?? ""
    }

    static func setIosTTSVoiceId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "iosTTSVoiceId")
    }

    /// Which TTS engine to prefer (Additional Capabilities #1 — the Kokoro on-device tier).
    /// Drives `TTSEngineSelector`; defaults to `.auto` (the historical ElevenLabs→iOS behaviour,
    /// with on-device Kokoro inserted between them when it's available).
    static var ttsEnginePreference: TTSEnginePreference {
        guard let raw = UserDefaults.standard.string(forKey: "ttsEnginePreference"),
              let preference = TTSEnginePreference(rawValue: raw) else {
            return .auto
        }
        return preference
    }

    static func setTTSEnginePreference(_ preference: TTSEnginePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: "ttsEnginePreference")
    }

    /// Which speech-recognition engine to prefer (Additional Capabilities #8 — the on-device
    /// SenseVoice tier). Drives `ASREngineSelector`; defaults to `.auto` (Apple Speech today, switching
    /// to the offline on-device recognizer once its model is downloaded).
    static var asrEnginePreference: ASREnginePreference {
        guard let raw = UserDefaults.standard.string(forKey: "asrEnginePreference"),
              let preference = ASREnginePreference(rawValue: raw) else {
            return .auto
        }
        return preference
    }

    static func setASREnginePreference(_ preference: ASREnginePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: "asrEnginePreference")
    }

    // MARK: - App Mode

    static var appMode: AppMode {
        if let raw = UserDefaults.standard.string(forKey: "appMode"),
           let mode = AppMode(rawValue: raw) {
            return mode
        }
        return .direct
    }

    static func setAppMode(_ mode: AppMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
    }

    // MARK: - LiveAI Mode

    static var activeLiveAIModeId: String {
        UserDefaults.standard.string(forKey: "activeLiveAIModeId") ?? "standard"
    }

    static func setActiveLiveAIModeId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "activeLiveAIModeId")
    }

    static var activeLiveAIMode: LiveAIMode {
        LiveAIMode.builtIn.first(where: { $0.id == activeLiveAIModeId }) ?? LiveAIMode.builtIn[0]
    }

    // MARK: - Translation Mic Source

    /// When true, live translation uses the iPhone's built-in mic instead of glasses Bluetooth mic.
    /// Useful for translating what someone nearby is saying (their voice comes through the phone mic).
    @UserDefaultsBacked("usePhoneMicForTranslation", default: false) static var usePhoneMicForTranslation: Bool

    static func setUsePhoneMicForTranslation(_ enabled: Bool) { usePhoneMicForTranslation = enabled }

    // MARK: - Quick Actions

    static var quickActions: [QuickAction] {
        let base: [QuickAction]
        if let data = UserDefaults.standard.data(forKey: "quickActions"),
           let actions = try? JSONDecoder().decode([QuickAction].self, from: data),
           !actions.isEmpty {
            let merged = mergeBuiltInQuickActions(into: actions)
            if merged.count != actions.count {
                setQuickActions(merged)
            }
            base = merged
        } else {
            base = QuickAction.defaults
        }
        return withFieldAssistAction(base)
    }

    /// Surface the built-in Field Assist quick action (first) when the feature is active.
    /// Recomputed each read so it tracks the entitlement/toggle: any stale/persisted copy is
    /// stripped, then re-added only when active — so it never lingers after a lapsed license.
    private static func withFieldAssistAction(_ actions: [QuickAction]) -> [QuickAction] {
        let base = actions.filter { $0.id != QuickAction.fieldAssist.id }
        return fieldAssistActive ? [QuickAction.fieldAssist] + base : base
    }

    static func setQuickActions(_ actions: [QuickAction]) {
        if let data = try? JSONEncoder().encode(actions) {
            UserDefaults.standard.set(data, forKey: "quickActions")
        }
    }

    /// Append any built-in actions (travel templates, the record toggle) a user's persisted
    /// list predates, so new built-ins reach existing installs — same merge semantics the
    /// travel templates have always had.
    private static func mergeBuiltInQuickActions(into actions: [QuickAction]) -> [QuickAction] {
        var merged = actions
        let existingIds = Set(actions.map(\.id))
        for template in QuickAction.travelTemplates + [QuickAction.recordMeeting]
        where !existingIds.contains(template.id) {
            merged.append(template)
        }
        return merged
    }

    /// Whether to show all quick actions on the Voice tab, or only the top 4.
    @UserDefaultsBacked("showAllQuickActions", default: false) static var showAllQuickActions: Bool

    static func setShowAllQuickActions(_ show: Bool) { showAllQuickActions = show }

    // MARK: - Speech Recognition Locale

    /// Which locale the speech features (wake word, transcription, captions, rewind, teleprompter)
    /// recognize in. `"auto"` follows the device's preferred language; an explicit identifier
    /// (e.g. `"de-DE"`) pins it. Resolved against what `SFSpeechRecognizer` actually supports —
    /// see `SpeechLocaleResolver`. Default `"auto"` (was hardcoded en-US everywhere).
    @UserDefaultsBacked("speechRecognitionLocale", default: "auto") static var speechRecognitionLocale: String

    static func setSpeechRecognitionLocale(_ id: String) { speechRecognitionLocale = id }

    // MARK: - Simple Mode

    /// Hide the owner-only configuration surface in Settings (models, personas, behavior, tools,
    /// integrations, advanced) — for handing the device to someone who just needs it to work.
    /// Pure UI gating: nothing about routing or behavior changes. Default off.
    @UserDefaultsBacked("simpleModeEnabled", default: false) static var simpleModeEnabled: Bool

    /// Require device-owner auth (Face ID / passcode) to open Settings at all (BM P10). Exiting
    /// Simple Mode always asks regardless of this flag. Default off.
    @UserDefaultsBacked("settingsOwnerGateEnabled", default: false) static var settingsOwnerGateEnabled: Bool

    // MARK: - Uncertainty Web Search (Plan BI)

    /// Local backends (MLX, Apple Foundation) can't tool-call `web_search`; when on, a hedged or
    /// freshness-sensitive local answer gets one transparent web-grounded re-ask. Default on —
    /// `WebSearchTool` always has the keyless DuckDuckGo fallback, so no configuration is needed.
    @UserDefaultsBacked("localWebSearchFallbackEnabled", default: true) static var localWebSearchFallbackEnabled: Bool

    // MARK: - Remote Invoke (Plan BH)

    // Per-class consent for gateway-initiated device commands. The whole surface additionally
    // gates on `agentModeEnabled`; capture (photo/video/audio/transcription/translation) is the
    // surveillance class and defaults OFF.
    @UserDefaultsBacked("remoteInvokeObserveEnabled", default: true) static var remoteInvokeObserveEnabled: Bool
    @UserDefaultsBacked("remoteInvokeOutputEnabled", default: true) static var remoteInvokeOutputEnabled: Bool
    @UserDefaultsBacked("remoteInvokeCaptureEnabled", default: false) static var remoteInvokeCaptureEnabled: Bool

    static var remoteInvokeToggles: RemoteCommandPolicy.Toggles {
        RemoteCommandPolicy.Toggles(
            observe: remoteInvokeObserveEnabled,
            output: remoteInvokeOutputEnabled,
            capture: remoteInvokeCaptureEnabled
        )
    }

    // MARK: - OpenClaw Configuration

    @UserDefaultsBacked("openClawEnabled", default: false) static var openClawEnabled: Bool

    static func setOpenClawEnabled(_ enabled: Bool) { openClawEnabled = enabled }

    static var openClawConnectionMode: OpenClawConnectionMode {
        if let raw = UserDefaults.standard.string(forKey: "openClawConnectionMode"),
           let mode = OpenClawConnectionMode(rawValue: raw) {
            return mode
        }
        return .auto
    }

    static func setOpenClawConnectionMode(_ mode: OpenClawConnectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "openClawConnectionMode")
    }

    static var openClawLanHost: String {
        UserDefaults.standard.string(forKey: "openClawLanHost") ?? "http://macbook.local"
    }

    static func setOpenClawLanHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawLanHost")
    }

    static var openClawPort: Int {
        let port = UserDefaults.standard.integer(forKey: "openClawPort")
        return port != 0 ? port : 18789
    }

    static func setOpenClawPort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: "openClawPort")
    }

    static var openClawTunnelHost: String {
        if let host = UserDefaults.standard.string(forKey: "openClawTunnelHost"), !host.isEmpty {
            return host
        }
        return ""
    }

    static func setOpenClawTunnelHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: "openClawTunnelHost")
    }

    /// OpenClaw gateway auth token. Stored in the Keychain (see `KeychainService`).
    static var openClawGatewayToken: String {
        if let token = KeychainService.string(for: "openClawGatewayToken"), !token.isEmpty {
            return token
        }
        return ""
    }

    static func setOpenClawGatewayToken(_ token: String) {
        KeychainService.setString(token, for: "openClawGatewayToken")
    }

    static var isOpenClawConfigured: Bool {
        // True if legacy single-gateway is configured OR any multi-gateway is configured
        (openClawEnabled && !openClawGatewayToken.isEmpty) || !enabledGateways.isEmpty
    }

    /// The gateway is an autonomous/agentic capability, so exposing or invoking it requires BOTH a
    /// configured gateway AND Agent Mode on (BK P0 — the house rule that all gateway/autonomous
    /// features sit behind `agentModeEnabled`). Every `execute`/`openclaw_skills` exposure and
    /// delegation gate reads this, so the surface can never advertise or run while Agent Mode is off.
    static var isOpenClawAgentActive: Bool {
        isOpenClawConfigured && agentModeEnabled
    }

    // MARK: - Multi-Gateway Configuration

    /// All configured gateways, sorted by priority (lower = first). Persisted in the
    /// Keychain because each `GatewayConfig` embeds an auth `token` (see `KeychainService`).
    static var savedGateways: [GatewayConfig] {
        guard let data = KeychainService.data(for: "savedGateways"),
              let gateways = try? JSONDecoder().decode([GatewayConfig].self, from: data) else {
            // Auto-migrate legacy single-gateway config on first access
            if openClawEnabled && !openClawGatewayToken.isEmpty {
                let legacy = GatewayConfig(
                    id: "legacy-openclaw",
                    name: "OpenClaw",
                    provider: GatewayProvider.openclaw.rawValue,
                    lanHost: openClawLanHost,
                    port: openClawPort,
                    tunnelHost: openClawTunnelHost,
                    token: openClawGatewayToken,
                    connectionMode: openClawConnectionMode.rawValue,
                    enabled: true,
                    priority: 0
                )
                // Persist the migration so it only happens once
                setSavedGateways([legacy])
                NSLog("[Config] Migrated legacy OpenClaw config to gateway system")
                return [legacy]
            }
            return []
        }
        return gateways.sorted { $0.priority < $1.priority }
    }

    static func setSavedGateways(_ gateways: [GatewayConfig]) {
        guard let data = try? JSONEncoder().encode(gateways) else { return }
        KeychainService.setData(data, for: "savedGateways")
    }

    // MARK: - Device pairing persistence

    /// Persist the pairing result for a gateway: store the per-device token (clearing the
    /// transient setup code once it lands) and/or the device id.
    static func setDeviceCredentials(gatewayId: String, deviceToken: String? = nil, deviceId: String? = nil) {
        var gateways = savedGateways
        guard let idx = gateways.firstIndex(where: { $0.id == gatewayId }) else { return }
        if let deviceToken {
            gateways[idx].deviceToken = deviceToken
            gateways[idx].setupCode = nil
        }
        if let deviceId { gateways[idx].deviceId = deviceId }
        setSavedGateways(gateways)
    }

    /// Store a setup code on a gateway so the next connect attempts bootstrap pairing.
    static func setGatewaySetupCode(gatewayId: String, setupCode: String) {
        var gateways = savedGateways
        guard let idx = gateways.firstIndex(where: { $0.id == gatewayId }) else { return }
        gateways[idx].setupCode = setupCode
        setSavedGateways(gateways)
    }

    /// The stable device id for a gateway, generating + persisting one if absent.
    static func deviceId(forGateway gatewayId: String) -> String {
        var gateways = savedGateways
        guard let idx = gateways.firstIndex(where: { $0.id == gatewayId }) else { return "" }
        if let existing = gateways[idx].deviceId, !existing.isEmpty { return existing }
        let newId = UUID().uuidString
        gateways[idx].deviceId = newId
        setSavedGateways(gateways)
        return newId
    }

    /// Enabled gateways only, in priority order.
    static var enabledGateways: [GatewayConfig] {
        savedGateways.filter { $0.enabled && $0.isConfigured }
    }

    /// Whether any gateway is configured and enabled.
    static var isAnyGatewayConfigured: Bool {
        !enabledGateways.isEmpty || isOpenClawConfigured
    }

    // MARK: - Gemini Live Configuration

    static var geminiLiveModelConfig: ModelConfig? {
        if let active = activeModel, active.llmProvider == .gemini {
            return active
        }
        return savedModels.first(where: { $0.provider == LLMProvider.gemini.rawValue })
    }

    static var geminiLiveAPIKey: String {
        return geminiLiveModelConfig?.apiKey ?? ""
    }

    /// The model id the user configured, if any. What actually goes on the wire is decided at
    /// connect time against the list the account offers — see `GeminiLiveModelCatalog`.
    static var geminiLiveConfiguredModel: String? { geminiLiveModelConfig?.model }

    static let geminiLiveWebSocketBaseURL =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    static var geminiLiveWebSocketURL: URL? {
        let key = geminiLiveAPIKey
        guard !key.isEmpty else { return nil }
        return URL(string: "\(geminiLiveWebSocketBaseURL)?key=\(key)")
    }

    static let geminiLiveInputSampleRate: Double = 16000
    static let geminiLiveOutputSampleRate: Double = 24000
    static let geminiLiveAudioChannels: UInt32 = 1
    static let geminiLiveAudioBitsPerSample: UInt32 = 16
    static let geminiLiveVideoFrameInterval: TimeInterval = 1.0
    static let geminiLiveVideoJPEGQuality: CGFloat = 0.5

    static var isGeminiLiveConfigured: Bool {
        !geminiLiveAPIKey.isEmpty
    }

    /// Two-phase tool responses for Gemini Live: declare functions NON_BLOCKING, ack a
    /// slow call fast (`willContinue` + SILENT) so the model's open transaction closes,
    /// then deliver the real result WHEN_IDLE so it never barges into the user's turn.
    /// Default OFF until validated against the live endpoint on device — the setup and
    /// response payload shapes change when enabled.
    static var geminiNonBlockingToolsEnabled: Bool {
        UserDefaults.standard.object(forKey: "geminiNonBlockingToolsEnabled") as? Bool ?? false
    }

    static func setGeminiNonBlockingToolsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "geminiNonBlockingToolsEnabled")
    }

    /// Plan CC P2 — voice-processing echo cancellation for phone-mode live sessions (open mic +
    /// barge-in). Default OFF until the device matrix in the plan doc passes: the failure mode it
    /// risks (capture silenced entirely on some OS builds) is strictly worse than the half-duplex
    /// mute it replaces, and the automatic fallback needs proving on hardware first.
    static var duplexAudioEnabled: Bool {
        UserDefaults.standard.object(forKey: "duplexAudioEnabled") as? Bool ?? false
    }

    static func setDuplexAudioEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "duplexAudioEnabled")
    }

    // MARK: - Skill packs (Plan BX)

    /// Signed catalog index URL. Default is the repo's GitHub Pages deployment (the catalog is a
    /// committed file; publishing is a git push). Enterprises can point at their own index —
    /// whatever serves it must serve the signed envelope shape `SkillPackCatalog.parse` expects.
    static var skillPackCatalogURL: String {
        UserDefaults.standard.string(forKey: "skillPackCatalogURL")
            ?? "https://straff2002.github.io/OpenGlasses/skillpacks/catalog.json"
    }

    static func setSkillPackCatalogURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "skillPackCatalogURL")
    }

    /// Admits UNSIGNED pack installs (loudly labeled). For pack authors; never loosens catalog
    /// index verification.
    static var skillPackDevModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "skillPackDevModeEnabled")
    }

    static func setSkillPackDevModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "skillPackDevModeEnabled")
    }

    // MARK: - Captions (Plan BY)

    /// Rolling compaction + endpoint debouncing under ambient captions. Default ON — behavior-
    /// preserving for short utterances by construction (a single-segment caption renders and
    /// finalizes identically); the flag exists as the field kill switch, not a beta gate.
    static var captionCompactionEnabled: Bool {
        UserDefaults.standard.object(forKey: "captionCompactionEnabled") as? Bool ?? true
    }

    static func setCaptionCompactionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "captionCompactionEnabled")
    }

    // MARK: - OpenAI Realtime Configuration

    /// Find the best OpenAI model config for Realtime mode.
    /// Prefers a model with "realtime" in the name, falls back to any OpenAI model.
    static var openAIRealtimeModelConfig: ModelConfig? {
        let openAIModels = savedModels.filter { $0.provider == LLMProvider.openai.rawValue }
        // Prefer a model explicitly named for realtime
        if let realtime = openAIModels.first(where: { $0.model.lowercased().contains("realtime") }) {
            return realtime
        }
        // Fall back to active model if it's OpenAI
        if let active = activeModel, active.llmProvider == .openai {
            return active
        }
        // Fall back to any OpenAI model
        return openAIModels.first
    }

    static var isOpenAIRealtimeConfigured: Bool {
        openAIRealtimeModelConfig != nil
    }

    // MARK: - Recording

    /// Explicit user override for the recording bitrate, or `nil` to let `VideoBitratePolicy`
    /// derive it from the encoded frame size and frame rate. There is deliberately no default
    /// here any more: a constant cannot be right for both 360×640 and 720×1280.
    static var recordingBitrateOverride: Int? {
        let val = UserDefaults.standard.integer(forKey: "recordingBitrate")
        return val > 0 ? val : nil
    }

    /// Set the override, or pass `nil` to clear it and go back to the derived bitrate.
    static func setRecordingBitrate(_ bitrate: Int?) {
        if let bitrate, bitrate > 0 {
            UserDefaults.standard.set(bitrate, forKey: "recordingBitrate")
        } else {
            UserDefaults.standard.removeObject(forKey: "recordingBitrate")
        }
    }

    /// User-selected folder bookmark for saving transcripts and recordings.
    /// If nil, defaults to Documents/Transcripts.
    static var transcriptFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "transcriptFolderBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptFolderBookmark") }
    }

    /// Resolve the transcript folder bookmark to a URL. Returns nil if bookmark is stale.
    static var transcriptFolderURL: URL? {
        guard let bookmark = transcriptFolderBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            // Re-bookmark if stale
            if let fresh = try? url.bookmarkData() {
                transcriptFolderBookmark = fresh
            }
        }
        return url
    }

    static func setTranscriptFolderURL(_ url: URL) {
        if let bookmark = try? url.bookmarkData() {
            transcriptFolderBookmark = bookmark
        }
    }

    static func clearTranscriptFolder() {
        transcriptFolderBookmark = nil
    }

    /// Whether a finished recording is also saved to the Photos "Glasses" album. Default on.
    /// Switching it off does not risk the recording: the copy in Documents/Recordings is written
    /// first and unconditionally.
    static var recordingSaveToPhotos: Bool {
        if UserDefaults.standard.object(forKey: "recordingSaveToPhotos") == nil { return true }
        return UserDefaults.standard.bool(forKey: "recordingSaveToPhotos")
    }

    static func setRecordingSaveToPhotos(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "recordingSaveToPhotos")
    }

    /// User-selected folder bookmark for an extra copy of every finished recording.
    /// If nil, recordings live in Documents/Recordings (plus Photos, when that is on).
    static var recordingFolderBookmark: Data? {
        get { UserDefaults.standard.data(forKey: "recordingFolderBookmark") }
        set { UserDefaults.standard.set(newValue, forKey: "recordingFolderBookmark") }
    }

    /// Resolve the recording folder bookmark to a URL. Returns nil if the bookmark is stale.
    static var recordingFolderURL: URL? {
        guard let bookmark = recordingFolderBookmark else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            if let fresh = try? url.bookmarkData() {
                recordingFolderBookmark = fresh
            }
        }
        return url
    }

    static func setRecordingFolderURL(_ url: URL) {
        if let bookmark = try? url.bookmarkData() {
            recordingFolderBookmark = bookmark
        }
    }

    static func clearRecordingFolder() {
        recordingFolderBookmark = nil
    }

    // MARK: - HIPAA Compliance

    /// Master toggle for HIPAA-compliant mode.
    /// When enabled: encrypts files at rest, disables cloud memory sync, prefers local LLM,
    /// disables web search, excludes data from iCloud backup, enforces retention policies.
    static var hipaaMode: Bool {
        get { UserDefaults.standard.bool(forKey: "hipaaMode") }
        set { UserDefaults.standard.set(newValue, forKey: "hipaaMode") }
    }

    /// Data retention period in days. Transcripts/recordings older than this are auto-purged.
    /// 0 = no auto-purge (manual deletion only). Default 90 days.
    static var hipaaRetentionDays: Int {
        get {
            // Unset → default 90. An explicit 0 is preserved and means "no auto-purge"
            // (enforceRetentionPolicy guards on > 0).
            guard UserDefaults.standard.object(forKey: "hipaaRetentionDays") != nil else { return 90 }
            return max(0, UserDefaults.standard.integer(forKey: "hipaaRetentionDays"))
        }
        set { UserDefaults.standard.set(newValue, forKey: "hipaaRetentionDays") }
    }

    /// Force all LLM queries through local on-device model when HIPAA mode is active.
    /// If false, cloud LLMs can still be used but a BAA warning is shown.
    static var hipaaLocalOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "hipaaLocalOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "hipaaLocalOnly") }
    }

    /// Tools disabled under HIPAA mode to prevent PHI leakage.
    static let hipaaDisabledTools: Set<String> = [
        "web_search",           // Don't leak clinical queries to search engines
        "send_message",         // Block uncontrolled messaging of PHI
        "send_via",             // Block multi-channel messaging of PHI
        "openclaw_skills",      // No gateway skill execution with PHI
        "reading_session",      // No passive camera OCR of documents — a "book" can be a chart
    ]

    // MARK: - Medical Export

    /// Auto-export transcript to configured platform when recording stops.
    static var autoExportEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoExportEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "autoExportEnabled") }
    }

    /// Default export format for manual sharing.
    static var defaultExportFormat: ExportFormat {
        get {
            let raw = UserDefaults.standard.string(forKey: "defaultExportFormat") ?? ""
            return ExportFormat.allCases.first { $0.rawValue == raw } ?? .plainText
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "defaultExportFormat") }
    }

    // MARK: - MCP Servers

    /// Persisted in the Keychain because each `MCPServerConfig` embeds auth `headers`
    /// (e.g. `Authorization: Bearer …`) — see `KeychainService`.
    static var mcpServers: [MCPServerConfig] {
        guard let data = KeychainService.data(for: "mcpServers"),
              let servers = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return []
        }
        return servers
    }

    static func setMCPServers(_ servers: [MCPServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) {
            KeychainService.setData(data, for: "mcpServers")
        }
    }

    // MARK: - Home Assistant

    static var homeAssistantURL: String {
        UserDefaults.standard.string(forKey: "homeAssistantURL") ?? ""
    }

    static func setHomeAssistantURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "homeAssistantURL")
    }

    /// Home Assistant long-lived access token. Stored in the Keychain (see `KeychainService`).
    static var homeAssistantToken: String {
        KeychainService.string(for: "homeAssistantToken") ?? ""
    }

    static func setHomeAssistantToken(_ token: String) {
        KeychainService.setString(token, for: "homeAssistantToken")
    }

    // MARK: - Live Broadcast

    static var broadcastPlatform: String {
        UserDefaults.standard.string(forKey: "broadcastPlatform") ?? "youtube"
    }

    static func setBroadcastPlatform(_ platform: String) {
        UserDefaults.standard.set(platform, forKey: "broadcastPlatform")
    }

    /// BS P2: broadcast output orientation ("portrait" | "landscape").
    static var broadcastOrientation: String {
        UserDefaults.standard.string(forKey: "broadcastOrientation") ?? "portrait"
    }
    static func setBroadcastOrientation(_ value: String) {
        UserDefaults.standard.set(value, forKey: "broadcastOrientation")
    }

    /// BS P3: starting video source for a broadcast (BroadcastVideoSource rawValue).
    static var broadcastDefaultSource: String {
        UserDefaults.standard.string(forKey: "broadcastDefaultSource") ?? "glasses"
    }
    static func setBroadcastDefaultSource(_ value: String) {
        UserDefaults.standard.set(value, forKey: "broadcastDefaultSource")
    }

    /// Plan CZ: let the assistant's spoken replies into stream and recording audio when they play
    /// out of the phone speaker. Off by default — a clean capture is what almost everyone wants,
    /// and the wearer already hears the reply. A streamer whose audience is following the
    /// conversation turns it on.
    static var captureIncludesAssistantVoice: Bool {
        UserDefaults.standard.bool(forKey: "captureIncludesAssistantVoice")
    }
    static func setCaptureIncludesAssistantVoice(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "captureIncludesAssistantVoice")
    }

    /// BS P3: picture-in-picture dual capture (phone inset over the main source).
    static var broadcastDualCapture: Bool {
        UserDefaults.standard.bool(forKey: "broadcastDualCapture")
    }
    static func setBroadcastDualCapture(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "broadcastDualCapture")
    }

    static var broadcastRTMPURL: String {
        UserDefaults.standard.string(forKey: "broadcastRTMPURL") ?? ""
    }

    static func setBroadcastRTMPURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "broadcastRTMPURL")
    }

    /// RTMP broadcast stream key (a publishing credential). Stored in the Keychain (see `KeychainService`).
    static var broadcastStreamKey: String {
        KeychainService.string(for: "broadcastStreamKey") ?? ""
    }

    static func setBroadcastStreamKey(_ key: String) {
        KeychainService.setString(key, for: "broadcastStreamKey")
    }

    static var isBroadcastConfigured: Bool {
        !broadcastRTMPURL.isEmpty && !broadcastStreamKey.isEmpty
    }

    // MARK: - Broadcast Encoding (Plan CY)

    /// Frame rate the RTMP encoder targets, in fps.
    ///
    /// Deliberately separate from `cameraFrameRate`: the glasses link and the uplink are different
    /// budgets. The camera tier may be dialled down to save the glasses' battery while the
    /// broadcast still wants every frame that arrives, and the broadcaster used to ignore both and
    /// hardcode 15 — a number that produced visibly juddery motion on an ingest that would happily
    /// have taken 30.
    static var broadcastFrameRate: Int {
        let value = UserDefaults.standard.integer(forKey: "broadcastFrameRate")
        return broadcastFrameRateChoices.contains(value) ? value : 30
    }

    /// The rates the picker offers (and the only ones accepted).
    static let broadcastFrameRateChoices = [15, 24, 30]

    static func setBroadcastFrameRate(_ fps: Int) {
        UserDefaults.standard.set(fps, forKey: "broadcastFrameRate")
    }

    /// Explicit user override for the broadcast video bitrate, or `nil` to let
    /// `VideoBitratePolicy` derive it from the output geometry and frame rate. Same shape as
    /// `recordingBitrateOverride`, and for the same reason — one constant cannot be right for both
    /// a portrait 720×1280 stream and a landscape one at half the frame rate.
    ///
    /// Note this sets the *ceiling*: adaptation may step below it on a struggling link, and never
    /// climbs above it.
    static var broadcastBitrateOverride: Int? {
        let value = UserDefaults.standard.integer(forKey: "broadcastBitrate")
        return value > 0 ? value : nil
    }

    static func setBroadcastBitrate(_ bitrate: Int?) {
        if let bitrate, bitrate > 0 {
            UserDefaults.standard.set(bitrate, forKey: "broadcastBitrate")
        } else {
            UserDefaults.standard.removeObject(forKey: "broadcastBitrate")
        }
    }

    /// Seconds between forced keyframes. Every ingest cuts its HLS/DASH segments on keyframes, so
    /// this is what decides how long a new viewer waits for a picture and how coarse a seek is.
    /// Two seconds is the interval the common ingests ask for; longer saves bits, shorter costs
    /// them.
    static var broadcastKeyframeIntervalSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: "broadcastKeyframeIntervalSeconds")
        return broadcastKeyframeIntervalChoices.contains(value) ? value : 2
    }

    static let broadcastKeyframeIntervalChoices = [1, 2, 4]

    static func setBroadcastKeyframeIntervalSeconds(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: "broadcastKeyframeIntervalSeconds")
    }

    /// AAC bitrate for the broadcast's audio track, bits/sec. The encoder default is 64 kbps,
    /// which is audibly thin for anything but speech in a quiet room; 128 kbps is the usual live
    /// figure and costs a rounding error against the video.
    static var broadcastAudioBitrate: Int {
        let value = UserDefaults.standard.integer(forKey: "broadcastAudioBitrate")
        return broadcastAudioBitrateChoices.contains(value) ? value : 128_000
    }

    static let broadcastAudioBitrateChoices = [64_000, 96_000, 128_000, 192_000]

    static func setBroadcastAudioBitrate(_ bitrate: Int) {
        UserDefaults.standard.set(bitrate, forKey: "broadcastAudioBitrate")
    }

    // MARK: - Broadcast Chat Read-Aloud (Plan CI)

    /// Read the stream's chat to the wearer over TTS while broadcasting. Off by default.
    static var broadcastChatReadbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: "broadcastChatReadbackEnabled")
    }
    static func setBroadcastChatReadbackEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "broadcastChatReadbackEnabled")
    }

    /// The Twitch channel whose chat to read. The RTMP stream key is an opaque credential (no
    /// channel name in it), so the channel is set explicitly here — which also covers restreams.
    static var broadcastChatChannel: String {
        UserDefaults.standard.string(forKey: "broadcastChatChannel") ?? ""
    }
    static func setBroadcastChatChannel(_ value: String) {
        UserDefaults.standard.set(value, forKey: "broadcastChatChannel")
    }

    /// Max chat messages spoken per minute (rate cap). Default 6.
    static var broadcastChatRateCap: Int {
        let value = UserDefaults.standard.integer(forKey: "broadcastChatRateCap")
        return value > 0 ? value : 6
    }
    static func setBroadcastChatRateCap(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "broadcastChatRateCap")
    }

    /// Speak only messages that mention the channel handle.
    static var broadcastChatMentionsOnly: Bool {
        UserDefaults.standard.bool(forKey: "broadcastChatMentionsOnly")
    }
    static func setBroadcastChatMentionsOnly(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "broadcastChatMentionsOnly")
    }

    /// The readback rules assembled from Settings (streamer handle = the channel name).
    static var broadcastChatRules: ChatReadbackRules {
        var rules = ChatReadbackRules()
        rules.rateCapPerMinute = broadcastChatRateCap
        rules.mentionsOnly = broadcastChatMentionsOnly
        rules.streamerHandle = broadcastChatChannel
        return rules
    }

    // MARK: - Fingerspelling model (Plan CK)

    /// HuggingFace repo hosting the fingerspelling Core ML model (unpacked files: the
    /// mlpackage, `vocab.txt`, and the holistic landmarker task — see
    /// `FingerspellingModelBundle`). Default is the published gate-passing artefact
    /// (20.8% CER on the competition-corpus gate, published 2026-08-05); override via
    /// UserDefaults to trial a staged alternative.
    static let fingerspellingModelRepoDefault = "Skunk0/openglasses-fingerspelling-ctc"
    static var fingerspellingModelRepo: String {
        let stored = UserDefaults.standard.string(forKey: "fingerspellingModelRepo")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return fingerspellingModelRepoDefault }
        return stored
    }
    static func setFingerspellingModelRepo(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "fingerspellingModelRepo")
    }

    // MARK: - Gemini via Vertex AI (Plan AI — Google OAuth provider)

    /// The user's own GCP OAuth *iOS* client ID (`…apps.googleusercontent.com`). Not a secret;
    /// the account credential lives in the keychain via `GoogleOAuthService`.
    static var googleOAuthClientID: String {
        UserDefaults.standard.string(forKey: "googleOAuthClientID") ?? ""
    }
    static func setGoogleOAuthClientID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "googleOAuthClientID")
    }

    /// GCP project ID — a path component of every Vertex endpoint URL.
    static var vertexProjectID: String {
        UserDefaults.standard.string(forKey: "vertexProjectID") ?? ""
    }
    static func setVertexProjectID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vertexProjectID")
    }

    /// Vertex region (host + path component). "global" uses the region-less host.
    static var vertexRegion: String {
        UserDefaults.standard.string(forKey: "vertexRegion") ?? "us-central1"
    }
    static func setVertexRegion(_ value: String) {
        UserDefaults.standard.set(value, forKey: "vertexRegion")
    }

    // MARK: - Camera Quality

    /// Camera stream resolution: "low" (360p), "medium" (504p), "high" (720p). Default: high.
    static var cameraResolution: String {
        UserDefaults.standard.string(forKey: "cameraResolution") ?? "high"
    }

    static func setCameraResolution(_ resolution: String) {
        UserDefaults.standard.set(resolution, forKey: "cameraResolution")
    }

    /// Camera stream frame rate. Default: 15.
    static var cameraFrameRate: Int {
        let rate = UserDefaults.standard.integer(forKey: "cameraFrameRate")
        return rate > 0 ? rate : 15
    }

    static func setCameraFrameRate(_ fps: Int) {
        UserDefaults.standard.set(fps, forKey: "cameraFrameRate")
    }

    // MARK: - LLM Image Compression

    /// How hard to shrink photos before they go to a vision model. Stored as the preset's raw
    /// value; an unrecognised string (an older build, a hand-edited default) reads as `.full`,
    /// which is the pre-preset behaviour.
    static var llmImagePreset: LLMImagePreset {
        UserDefaults.standard.string(forKey: "llmImagePreset").flatMap(LLMImagePreset.init(rawValue:)) ?? .full
    }

    static func setLLMImagePreset(_ preset: LLMImagePreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: "llmImagePreset")
    }

    /// Custom-preset knobs. Each is clamped against the provider ceiling when resolved (see
    /// `LLMImagePreparer.limits(for:)`) — a slider cannot raise a limit the API sets.
    static var llmImageCustomMaxLongEdge: Int {
        let v = UserDefaults.standard.object(forKey: "llmImageCustomMaxLongEdge") as? Int
        return v ?? 1568
    }

    static func setLLMImageCustomMaxLongEdge(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "llmImageCustomMaxLongEdge")
    }

    static var llmImageCustomMaxBytes: Int {
        let v = UserDefaults.standard.object(forKey: "llmImageCustomMaxBytes") as? Int
        return v ?? 1_500_000
    }

    static func setLLMImageCustomMaxBytes(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "llmImageCustomMaxBytes")
    }

    static var llmImageCustomJPEGQuality: CGFloat {
        let v = UserDefaults.standard.object(forKey: "llmImageCustomJPEGQuality") as? Double
        return v.map { CGFloat($0) } ?? 0.75
    }

    static func setLLMImageCustomJPEGQuality(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: "llmImageCustomJPEGQuality")
    }

    /// Legacy global "small context" switch, superseded by the per-model `ModelConfig.smallContext`.
    /// Kept only so `migrateSmallContextToPerModelIfNeeded()` can read what the user had set; no
    /// production decision may consult it.
    @UserDefaultsBacked("llmImageLightweightPromptEnabled", default: false) static var llmImageLightweightPromptEnabled: Bool

    static func setLLMImageLightweightPromptEnabled(_ enabled: Bool) {
        llmImageLightweightPromptEnabled = enabled
    }

    /// Carry a global small-context choice onto the models it actually applied to (cloud
    /// providers — on-device always ran lean), then clear the global flag so behaviour is
    /// per-model from here on. Safe to run every launch: once the flag is false it is a no-op.
    static func migrateSmallContextToPerModelIfNeeded() {
        guard llmImageLightweightPromptEnabled else { return }
        var models = savedModels
        for i in models.indices {
            let provider = models[i].llmProvider
            if provider != .local && provider != .appleOnDevice && models[i].smallContext == nil {
                models[i].smallContext = true
            }
        }
        setSavedModels(models)
        llmImageLightweightPromptEnabled = false
    }

    // MARK: - Perplexity Search

    /// Perplexity API key. Stored in the Keychain (see `KeychainService`).
    static var perplexityAPIKey: String {
        if let key = KeychainService.string(for: "perplexityAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setPerplexityAPIKey(_ key: String) {
        KeychainService.setString(key, for: "perplexityAPIKey")
    }

    static var isPerplexityConfigured: Bool {
        !perplexityAPIKey.isEmpty
    }

    // MARK: - Tavily Search

    /// Tavily API key. Stored in the Keychain (see `KeychainService`).
    static var tavilyAPIKey: String {
        if let key = KeychainService.string(for: "tavilyAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setTavilyAPIKey(_ key: String) {
        KeychainService.setString(key, for: "tavilyAPIKey")
    }

    static var isTavilyConfigured: Bool {
        !tavilyAPIKey.isEmpty
    }

    // MARK: - Brave Search

    /// Brave Search API key. Stored in the Keychain (see `KeychainService`).
    static var braveAPIKey: String {
        if let key = KeychainService.string(for: "braveAPIKey"), !key.isEmpty {
            return key
        }
        return ""
    }

    static func setBraveAPIKey(_ key: String) {
        KeychainService.setString(key, for: "braveAPIKey")
    }

    static var isBraveConfigured: Bool {
        !braveAPIKey.isEmpty
    }

    // MARK: - Hermes Agent Bridge (Plan CL P5)

    /// Route conversation turns through a Hermes agent bridge on the LAN.
    /// Like every gateway feature, only effective while Agent Mode is on.
    @UserDefaultsBacked("hermesBridgeEnabled", default: false) static var hermesBridgeEnabled: Bool
    static func setHermesBridgeEnabled(_ enabled: Bool) { hermesBridgeEnabled = enabled }

    @UserDefaultsBacked("hermesBridgeHost", default: "") static var hermesBridgeHost: String
    static func setHermesBridgeHost(_ host: String) { hermesBridgeHost = host }

    @UserDefaultsBacked("hermesBridgePort", default: HermesBridgeProtocol.defaultPort) static var hermesBridgePort: Int
    static func setHermesBridgePort(_ port: Int) { hermesBridgePort = port }

    /// Optional bridge auth token (`?token=`). Stored in the Keychain.
    static var hermesBridgeToken: String {
        KeychainService.string(for: "hermesBridgeToken") ?? ""
    }

    static func setHermesBridgeToken(_ token: String) {
        KeychainService.setString(token, for: "hermesBridgeToken")
    }

    // MARK: - Privacy Filter

    @UserDefaultsBacked("privacyFilterEnabled", default: false) static var privacyFilterEnabled: Bool

    static func setPrivacyFilterEnabled(_ enabled: Bool) { privacyFilterEnabled = enabled }

    /// Plan CO Item 1 — similarity gap the leading face must open over the runner-up before the
    /// name is spoken as a fact. Inside this margin the app names the possibilities instead of
    /// guessing. Configurable because the right value can only be found against real enrolments;
    /// raising it makes the app more cautious, lowering it more confidently wrong.
    @UserDefaultsBacked("faceMatchAmbiguityMargin", default: Double(FaceMatcher.defaultMargin))
    static var faceMatchAmbiguityMarginValue: Double

    static var faceMatchAmbiguityMargin: Float { Float(faceMatchAmbiguityMarginValue) }

    // MARK: - Agent Vision Attachment (Plan CN)

    /// Whether a delegated remote-agent task may carry a still from the wearer's camera.
    ///
    /// **Default off, and deliberately distinct from `agentModeEnabled`.** Agent Mode bought
    /// "dispatch text tasks to my agent"; quietly upgrading that to "and ship frames from a
    /// head-mounted camera to the same endpoint" is a scope expansion the user never agreed to.
    @UserDefaultsBacked("agentVisionAttachmentEnabled", default: false)
    static var agentVisionAttachmentEnabled: Bool

    static func setAgentVisionAttachmentEnabled(_ enabled: Bool) { agentVisionAttachmentEnabled = enabled }

    /// Beyond this age a held pin is a forgotten pin, not a statement about the present.
    @UserDefaultsBacked("agentVisionAttachmentMaxPinAge",
                        default: AgentAttachmentPolicy.defaultMaxPinAge)
    static var agentVisionAttachmentMaxPinAge: TimeInterval

    /// Category-only privacy reporting in vision prompts (Plan CJ item 4): the model reports
    /// *that* a sensitive item is visible but is schema-forbidden from transcribing its content.
    /// Default on — the language-side complement to the pixel-side face blur above.
    @UserDefaultsBacked("visionPrivacyCategoriesEnabled", default: true) static var visionPrivacyCategoriesEnabled: Bool

    static func setVisionPrivacyCategoriesEnabled(_ enabled: Bool) { visionPrivacyCategoriesEnabled = enabled }

    // MARK: - Health Data Sharing with AI

    /// Whether HealthKit-derived data (e.g. workout history) may be sent to the
    /// configured LLM provider as tool-call context.
    ///
    /// Apple App Review Guideline 5.1.3 requires explicit user consent before
    /// HealthKit data is disclosed to a third party — and an LLM API is a third
    /// party. This MUST default to false (opt-in). On-device tracking, form
    /// analysis, and saving workouts to Apple Health do not require it; only
    /// transmitting Health-read data off-device does.
    @UserDefaultsBacked("shareHealthDataWithAI", default: false) static var shareHealthDataWithAI: Bool

    static func setShareHealthDataWithAI(_ enabled: Bool) { shareHealthDataWithAI = enabled }

    // MARK: - Listening Toggle

    /// Master switch for wake word detection + Live Activity.
    /// When disabled, the app stops listening for wake words and ends the Live Activity.
    /// Can be toggled from Settings, Siri Shortcuts, or the Live Activity power button.
    static var listeningEnabled: Bool {
        let key = "listeningEnabled"
        // Prefer App Group defaults so widget/control toggles are visible immediately.
        let shared = SharedAppState.defaults
        if shared.object(forKey: key) != nil {
            return shared.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setListeningEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "listeningEnabled")
        SharedAppState.defaults.set(enabled, forKey: "listeningEnabled")
    }

    // MARK: - Emotion-Aware TTS

    static var emotionAwareTTSEnabled: Bool {
        let key = "emotionAwareTTSEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setEmotionAwareTTSEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "emotionAwareTTSEnabled")
    }

    // MARK: - Scene Narration (Plan CV)

    /// Whether continuous scene narration is available. Off by default: it runs the on-device VLM
    /// continuously, which is the most expensive thing in the app.
    ///
    /// This gates *availability*, not speech. The mode itself starts silent — watching and
    /// accumulating grounding context — and speaking is a separate, explicit request.
    static var sceneNarrationEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sceneNarrationEnabled")
    }

    static func setSceneNarrationEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "sceneNarrationEnabled")
    }

    // MARK: - Accent Color

    static var accentColorName: String {
        UserDefaults.standard.string(forKey: "accentColorName") ?? AppAccent.defaultPresetID
    }

    static func setAccentColorName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "accentColorName")
    }

    // MARK: - Mic Route (Plan CL P3)

    /// Unified capture route: phone / glasses / headset. Migrates the old
    /// `useGlassesMicForWakeWord` boolean (whose default was glasses-on).
    static var micRoute: MicRoute {
        if let raw = UserDefaults.standard.string(forKey: "micRoute"),
           let route = MicRoute(rawValue: raw) {
            return route
        }
        return useGlassesMicForWakeWord ? .glasses : .phone
    }

    static func setMicRoute(_ route: MicRoute) {
        UserDefaults.standard.set(route.rawValue, forKey: "micRoute")
        // Keep the legacy boolean coherent for anything that still reads it.
        UserDefaults.standard.set(route == .glasses, forKey: "useGlassesMicForWakeWord")
    }

    /// Legacy boolean, kept for migration and old readers. `.headset` counts
    /// as "not glasses" — the whole point is keeping the glasses link idle.
    static var useGlassesMicForWakeWord: Bool {
        let key = "useGlassesMicForWakeWord"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setUseGlassesMicForWakeWord(_ enabled: Bool) {
        setMicRoute(enabled ? .glasses : .phone)
    }

    /// Use on-device speech recognition for the always-on wake-word listener (Plan BE). Default on:
    /// short-phrase spotting doesn't need the server, and streaming mic audio to Apple 24/7 is the
    /// biggest steady battery/data drain. Real queries still use server recognition.
    static var onDeviceWakeWordEnabled: Bool {
        let key = "onDeviceWakeWordEnabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setOnDeviceWakeWordEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "onDeviceWakeWordEnabled")
    }

    // MARK: - Audio-Only Mode

    /// When enabled, disables video frame streaming to save battery. Voice still works.
    @UserDefaultsBacked("audioOnlyMode", default: false) static var audioOnlyMode: Bool

    static func setAudioOnlyMode(_ enabled: Bool) { audioOnlyMode = enabled }

    // MARK: - My Day

    /// Phone/audio-first everyday briefing. Off by default while the MVP rolls out; disabling it
    /// hides its surface and scheduled trigger without changing Calendar or Reminders data.
    @UserDefaultsBacked("myDayEnabled", default: false) static var myDayEnabled: Bool

    static func setMyDayEnabled(_ enabled: Bool) {
        myDayEnabled = enabled
        if enabled {
            MyDayMetricsStore.shared.record(.optedIn, at: Date())
        }
    }

    @UserDefaultsBacked("myDayTransportMode", default: MyDayTransportMode.walking.rawValue)
    private static var myDayTransportModeRaw: String

    static var myDayTransportMode: MyDayTransportMode {
        get { MyDayTransportMode(rawValue: myDayTransportModeRaw) ?? .walking }
        set { myDayTransportModeRaw = newValue.rawValue }
    }

    @UserDefaultsBacked("myDayTravelBufferMinutes", default: 10)
    private static var storedMyDayTravelBufferMinutes: Int

    static var myDayTravelBufferMinutes: Int {
        get { min(60, max(0, storedMyDayTravelBufferMinutes)) }
        set { storedMyDayTravelBufferMinutes = min(60, max(0, newValue)) }
    }

    @UserDefaultsBacked("myDayTravelOrigin", default: MyDayTravelOrigin.currentLocation.rawValue)
    private static var myDayTravelOriginRaw: String

    static var myDayTravelOrigin: MyDayTravelOrigin {
        get { MyDayTravelOrigin(rawValue: myDayTravelOriginRaw) ?? .currentLocation }
        set { myDayTravelOriginRaw = newValue.rawValue }
    }

    /// Explicit user-entered fallbacks. Event locations and resolved routes are never persisted.
    @UserDefaultsBacked("myDayHomeAddress", default: "") static var myDayHomeAddress: String
    @UserDefaultsBacked("myDayWorkAddress", default: "") static var myDayWorkAddress: String

    /// Content-free delivery state prevents one leave-by occurrence being repeated after relaunch.
    @UserDefaultsBacked("myDayLastDeliveredLeaveByID", default: "")
    static var myDayLastDeliveredLeaveByID: String

    // MARK: - Glasses Display (in-lens HUD)

    /// When enabled, AI responses and ambient captions are mirrored to the
    /// Ray-Ban Display in-lens HUD. No-ops on glasses without a display.
    @UserDefaultsBacked("glassesDisplayEnabled", default: false) static var glassesDisplayEnabled: Bool

    static func setGlassesDisplayEnabled(_ enabled: Bool) { glassesDisplayEnabled = enabled }

    // MARK: - Memory loop (self-improving)

    /// When on, the assistant offers a spoken nudge after you state a durable fact or repeat a
    /// multi-step request ("say 'remember it'" / "save that as a skill"). Off by default. When
    /// Agent Mode is also on, those are auto-saved silently instead of nudged.
    @UserDefaultsBacked("memoryNudgesEnabled", default: false) static var memoryNudgesEnabled: Bool

    static func setMemoryNudgesEnabled(_ enabled: Bool) { memoryNudgesEnabled = enabled }

    // MARK: - Teleprompter

    /// Default pacing mode for new teleprompter sessions.
    static var teleprompterMode: PacingMode {
        if let raw = UserDefaults.standard.string(forKey: "teleprompterMode"),
           let mode = PacingMode(rawValue: raw) {
            return mode
        }
        return .audioPaced
    }

    static func setTeleprompterMode(_ mode: PacingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "teleprompterMode")
    }

    /// Auto-scroll words-per-minute (also the live "faster/slower" baseline).
    static var teleprompterWPM: Int {
        let stored = UserDefaults.standard.integer(forKey: "teleprompterWPM")
        return PacingSpeed.wpmRange.contains(stored) ? stored : 130
    }

    static func setTeleprompterWPM(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "teleprompterWPM")
    }

    /// How many lines ahead of the spoken word the active line sits (audio-paced lead).
    static var teleprompterLead: Int {
        if UserDefaults.standard.object(forKey: "teleprompterLead") == nil { return 1 }
        let stored = UserDefaults.standard.integer(forKey: "teleprompterLead")
        return PacingSpeed.leadRange.contains(stored) ? stored : 1
    }

    static func setTeleprompterLead(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "teleprompterLead")
    }

    // MARK: - WebRTC Streaming

    static var webRTCSignalingURL: String {
        if let url = UserDefaults.standard.string(forKey: "webRTCSignalingURL"), !url.isEmpty {
            return url
        }
        return "wss://openglasses-signal.fly.dev/ws"
    }

    static func setWebRTCSignalingURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "webRTCSignalingURL")
    }

    static var webRTCViewerBaseURL: String {
        if let url = UserDefaults.standard.string(forKey: "webRTCViewerBaseURL"), !url.isEmpty {
            return url
        }
        return "https://openglasses-signal.fly.dev/view"
    }

    static func setWebRTCViewerBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "webRTCViewerBaseURL")
    }

    // MARK: - Intent Classifier

    @UserDefaultsBacked("intentClassifierEnabled", default: false) static var intentClassifierEnabled: Bool

    static func setIntentClassifierEnabled(_ enabled: Bool) { intentClassifierEnabled = enabled }

    // MARK: - Smart Camera

    /// When enabled, automatically activates the glasses camera when a vision-related query is detected.
    /// Saves battery by keeping the camera off for text-only questions.
    static var smartCameraEnabled: Bool {
        let key = "smartCameraEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setSmartCameraEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "smartCameraEnabled")
    }

    /// Seconds to keep the camera active after a vision query (for follow-up questions).
    static var smartCameraCooldown: TimeInterval {
        let val = UserDefaults.standard.double(forKey: "smartCameraCooldown")
        return val > 0 ? val : 5.0
    }

    static func setSmartCameraCooldown(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: "smartCameraCooldown")
    }

    /// Camera behavior for the active preset: "smart", "always", or nil (default = smart if enabled).
    static var activePresetCameraBehavior: String? {
        activePreset?.cameraBehavior
    }

    // MARK: - User Memory

    static var userMemoryEnabled: Bool {
        let key = "userMemoryEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setUserMemoryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "userMemoryEnabled")
    }

    // MARK: - Skill Retrieval

    /// When `true`, the skill stores inject only the skills relevant to the current turn (exact
    /// trigger matches + top-K by embedding similarity) instead of dumping the whole library.
    /// **Default on** (beta) — a no-op below `skillRetrievalMinCount` skills (so most users are
    /// unaffected), and exact trigger matches are always kept; it only trims once the bank grows.
    /// Set off to restore the unconditional dump. See [[SkillRetriever]].
    static var skillRetrievalEnabled: Bool {
        let key = "skillRetrievalEnabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setSkillRetrievalEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "skillRetrievalEnabled")
    }

    /// Soft budget: how many skills to inject when retrieval is on (exact trigger matches are always
    /// kept and may exceed this). Falls back to a sensible default when unset.
    static var skillRetrievalTopK: Int {
        let v = UserDefaults.standard.integer(forKey: "skillRetrievalTopK")
        return v > 0 ? v : 6
    }

    /// Floor below which retrieval is a no-op (dumping a handful is cheaper than ranking them).
    static var skillRetrievalMinCount: Int {
        let key = "skillRetrievalMinCount"
        if UserDefaults.standard.object(forKey: key) == nil { return 8 }
        return UserDefaults.standard.integer(forKey: key)
    }

    // MARK: - Project Memory

    /// When `true`, notes scoped to the active Field Assist job (see [[ProjectMemory]]) are injected
    /// into the prompt while that job is active. **Default on** (beta) — purely additive context that
    /// only appears with an active job and saved notes; without it, `project_note` would save notes
    /// that never surface. Flag is the kill-switch.
    static var projectMemoryEnabled: Bool {
        let key = "projectMemoryEnabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setProjectMemoryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "projectMemoryEnabled")
    }

    // MARK: - User Memory Retrieval

    /// When `true`, the shared-memory injection passes the current turn as a query to
    /// `SemanticMemoryStore.systemPromptContext(query:)`, so only the facts relevant to the turn are
    /// injected (its existing top-8 semantic search) instead of dumping every fact. **Default on**
    /// (beta) — leaner token use; falls back to a full dump when the search returns nothing. Set off
    /// to restore the unconditional dump.
    static var userMemoryRetrievalEnabled: Bool {
        let key = "userMemoryRetrievalEnabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setUserMemoryRetrievalEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "userMemoryRetrievalEnabled")
    }

    // MARK: - Contextual Embeddings

    /// When `true`, [[Embedder]] prefers the transformer `NLContextualEmbedding` over the lookup-based
    /// `NLEmbedding` for semantic search (sharper RAG + memory retrieval). **Default off** — it downloads
    /// an OTA asset on first use and, being a different model, re-embeds stored vectors via the version
    /// stamp (a one-time cost). Until the asset is present, `Embedder` transparently falls back to
    /// `NLEmbedding`, so flipping this on is safe. Enable on-device to validate the quality lift.
    @UserDefaultsBacked("contextualEmbeddingEnabled", default: false) static var contextualEmbeddingEnabled: Bool

    static func setContextualEmbeddingEnabled(_ enabled: Bool) { contextualEmbeddingEnabled = enabled }

    // MARK: - Model pricing overrides (Plan AU — Settings editor)

    /// User edits to the bundled `ModelPricing` table (USD per 1M tokens), keyed by
    /// the same model-id prefixes. Persisted locally; applied over the defaults.
    static var modelPricingOverrides: [String: ModelPricing.Rate] {
        guard let data = UserDefaults.standard.data(forKey: "modelPricingOverrides"),
              let dict = try? JSONDecoder().decode([String: ModelPricing.Rate].self, from: data) else { return [:] }
        return dict
    }

    /// Persist the overrides and apply them to the live `ModelPricing` table.
    static func setModelPricingOverrides(_ overrides: [String: ModelPricing.Rate]) {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: "modelPricingOverrides")
        }
        ModelPricing.overrides = overrides
    }

    /// Load persisted pricing overrides into `ModelPricing` (call once at launch).
    static func applyModelPricingOverrides() {
        ModelPricing.overrides = modelPricingOverrides
    }

    // MARK: - Content-Aware Frame Gate (Plan AT)

    /// When `true`, `FrameThrottler` consults a perceptual-hash `FrameGate` after
    /// its time check and drops frames that are visually indistinguishable from
    /// the last one sent. Defaults to `false`: the time-only throttle behaves
    /// exactly as before until this is turned on.
    @UserDefaultsBacked("frameDedupEnabled", default: false) static var frameDedupEnabled: Bool

    static func setFrameDedupEnabled(_ enabled: Bool) { frameDedupEnabled = enabled }

    /// Base dHash Hamming distance (of 64) at/below which two frames are treated
    /// as the same scene and the candidate is dropped. ~3–5 is "same scene".
    static var frameDedupHammingThreshold: Int {
        let v = UserDefaults.standard.object(forKey: "frameDedupHammingThreshold") as? Int
        return v ?? 4
    }

    static func setFrameDedupHammingThreshold(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "frameDedupHammingThreshold")
    }

    /// Seconds after the last sent frame before the gate forces one through even
    /// if everything since has been deduped, so the model's view can't go stale.
    static var frameDedupHeartbeatSeconds: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "frameDedupHeartbeatSeconds") as? Double
        return v ?? 12
    }

    static func setFrameDedupHeartbeatSeconds(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: "frameDedupHeartbeatSeconds")
    }

    // MARK: - Power Policy thresholds (Plan BV P1)
    //
    // Battery enter/exit percentages for the conserve/reserve postures. Code-only knobs (same
    // posture as frameDedup* above) so the device drain-session pass tunes them without a build.
    // Enter < exit gives the hysteresis band that stops the posture flapping at a boundary.
    // Thermal thresholds stay at the `PowerPolicy.Thresholds` enum defaults (serious→conserve,
    // critical→reserve) — the discrete bands don't hover the way a percentage does.

    static var powerConserveBatteryEnterPercent: Int {
        UserDefaults.standard.object(forKey: "powerConserveBatteryEnterPercent") as? Int ?? 30
    }
    static func setPowerConserveBatteryEnterPercent(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "powerConserveBatteryEnterPercent")
    }

    static var powerConserveBatteryExitPercent: Int {
        UserDefaults.standard.object(forKey: "powerConserveBatteryExitPercent") as? Int ?? 35
    }
    static func setPowerConserveBatteryExitPercent(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "powerConserveBatteryExitPercent")
    }

    static var powerReserveBatteryEnterPercent: Int {
        UserDefaults.standard.object(forKey: "powerReserveBatteryEnterPercent") as? Int ?? 15
    }
    static func setPowerReserveBatteryEnterPercent(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "powerReserveBatteryEnterPercent")
    }

    static var powerReserveBatteryExitPercent: Int {
        UserDefaults.standard.object(forKey: "powerReserveBatteryExitPercent") as? Int ?? 20
    }
    static func setPowerReserveBatteryExitPercent(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "powerReserveBatteryExitPercent")
    }

    /// The tunable thresholds assembled for `PowerPolicy.decide`; thermal bands stay at defaults.
    static var powerThresholds: PowerPolicy.Thresholds {
        PowerPolicy.Thresholds(
            conserveBatteryEnter: Double(powerConserveBatteryEnterPercent) / 100.0,
            conserveBatteryExit: Double(powerConserveBatteryExitPercent) / 100.0,
            reserveBatteryEnter: Double(powerReserveBatteryEnterPercent) / 100.0,
            reserveBatteryExit: Double(powerReserveBatteryExitPercent) / 100.0,
            conserveThermal: PowerPolicy.Thresholds.default.conserveThermal,
            reserveThermal: PowerPolicy.Thresholds.default.reserveThermal
        )
    }

    // MARK: - Reading Companion detector tuning (Plan BT P3)
    //
    // Config-backed so the P3 device pass (curved paperbacks, e-reader glare) is data-only —
    // retune without a build. Code-only knobs, same posture as frameDedup* above.

    /// dHash Hamming distance (of 64) at/below which the page detector treats two frames as the
    /// same view. Deliberately tighter than frameDedup's default: a book on a table is static.
    static var readingHammingThreshold: Int {
        let v = UserDefaults.standard.object(forKey: "readingHammingThreshold") as? Int
        return v ?? 3
    }

    static func setReadingHammingThreshold(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "readingHammingThreshold")
    }

    /// Seconds a page candidate must hold still before it's settled and sent to OCR.
    static var readingStabilityWindowSeconds: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "readingStabilityWindowSeconds") as? Double
        return v ?? 1.0
    }

    static func setReadingStabilityWindowSeconds(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: "readingStabilityWindowSeconds")
    }

    /// Floor on the gap between two evaluated reading frames — the battery lever.
    static var readingMinimumFrameInterval: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "readingMinimumFrameInterval") as? Double
        return v ?? 0.5
    }

    static func setReadingMinimumFrameInterval(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: "readingMinimumFrameInterval")
    }

    // MARK: - Visual State Memory (Plan AV)

    /// When `true`, the live agent keeps a short rolling memory of distinct scenes
    /// (keyframes from the frame gate, each one-line described) and injects a
    /// "Recent Visual Context" block into the session instruction. Defaults to
    /// `false`: the instruction is built exactly as before. Rides on the content
    /// gate, so `frameDedupEnabled` must also be on for keyframes to flow.
    @UserDefaultsBacked("visualStateMemoryEnabled", default: false) static var visualStateMemoryEnabled: Bool

    static func setVisualStateMemoryEnabled(_ enabled: Bool) { visualStateMemoryEnabled = enabled }

    /// Maximum keyframes retained in the rolling visual memory (and the cap on how
    /// many appear in the injected context). 5–8 covers "the last little while".
    static var visualStateMaxKeyframes: Int {
        let v = UserDefaults.standard.object(forKey: "visualStateMaxKeyframes") as? Int
        return v ?? 6
    }

    static func setVisualStateMaxKeyframes(_ value: Int) {
        UserDefaults.standard.set(value, forKey: "visualStateMaxKeyframes")
    }

    /// Minimum seconds between keyframe describe calls — a hard rate-limit so the
    /// per-keyframe LLM description stays a small, bounded cost.
    static var visualStateDescribeMinInterval: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "visualStateDescribeMinInterval") as? Double
        return v ?? 6
    }

    static func setVisualStateDescribeMinInterval(_ value: TimeInterval) {
        UserDefaults.standard.set(value, forKey: "visualStateDescribeMinInterval")
    }

    /// When `true`, keyframe thumbnails are persisted and may be attached to the
    /// agent turn (heavier). Default `false`: text-only "Recent Visual Context".
    @UserDefaultsBacked("visualStateInjectThumbnails", default: false) static var visualStateInjectThumbnails: Bool

    static func setVisualStateInjectThumbnails(_ enabled: Bool) { visualStateInjectThumbnails = enabled }

    // MARK: - Siri "Ask a Question" Behavior

    /// When `true`, the Siri "Ask OpenGlasses a question" intent brings the app to
    /// the foreground before answering. Default `false`: it runs in the background
    /// and Siri speaks the answer hands-free (OpenGlasses normally stays running to
    /// listen for wake words). Users whose app gets killed and see "OpenGlasses is
    /// not running" can enable this for reliability at the cost of launching the app.
    @UserDefaultsBacked("siriAskOpensApp", default: false) static var siriAskOpensApp: Bool

    static func setSiriAskOpensApp(_ enabled: Bool) { siriAskOpensApp = enabled }

    // MARK: - Silent Mode

    /// When enabled, the wake word listener is off but the agent is still actionable
    /// via the watch, widget quick actions, Action Button, and manual mic tap.
    /// Scheduled agent tasks still run in the background.
    @UserDefaultsBacked("silentMode", default: false) static var silentMode: Bool

    static func setSilentMode(_ enabled: Bool) { silentMode = enabled }

    // MARK: - Glasses-Only Audio

    /// When true, agent TTS and notification sounds are silenced if glasses are not connected.
    /// When false (default), audio plays through the phone speaker even without glasses.
    @UserDefaultsBacked("glassesOnlyAudio", default: false) static var glassesOnlyAudio: Bool

    static func setGlassesOnlyAudio(_ enabled: Bool) { glassesOnlyAudio = enabled }

// MARK: - Auto-Sleep

    /// Minutes of idle (glasses in case) before auto-disconnecting. 0 = disabled.
    static var autoSleepMinutes: Int {
        let val = UserDefaults.standard.integer(forKey: "autoSleepMinutes")
        return val > 0 ? val : 5  // Default 5 minutes
    }

    static func setAutoSleepMinutes(_ minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: "autoSleepMinutes")
    }

    // MARK: - Agentic Features Mode

    /// When enabled, the agent uses soul.md/skills.md/memory.md instead of prompt presets.
    /// The agent has its own identity and learns about the user over time.
    static var agentModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentModeEnabled")
    }

    static func setAgentModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "agentModeEnabled")
    }

    /// When on, an ambiguous request (action cues but no clear sequencer) is classified
    /// by a tiny LLM call to decide single- vs multi-step (Plan S Phase 2). Default off:
    /// the pure keyword heuristic alone decides, with no extra round-trip.
    @UserDefaultsBacked("llmComplexityClassifierEnabled", default: false) static var llmComplexityClassifierEnabled: Bool

    static func setLLMComplexityClassifierEnabled(_ enabled: Bool) { llmComplexityClassifierEnabled = enabled }

    // MARK: - Remote Agent Harness (Plan N)

    /// Which harness the Remote Agent Harness dispatches to by default. Defaults to `.openclaw`.
    static var defaultAgentHarness: AgentHarnessKind {
        AgentHarnessKind(rawValue: UserDefaults.standard.string(forKey: "defaultAgentHarness") ?? "")
            ?? .openclaw
    }

    static func setDefaultAgentHarness(_ kind: AgentHarnessKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: "defaultAgentHarness")
    }

    /// The Custom URL agent endpoint (Phase 2). Keychain-backed — it embeds an auth token. `nil`
    /// until the user configures one.
    static var customAgentHarness: CustomHarnessConfig? {
        guard let data = KeychainService.data(for: "customAgentHarness"),
              let config = try? JSONDecoder().decode(CustomHarnessConfig.self, from: data) else {
            return nil
        }
        return config
    }

    static func setCustomAgentHarness(_ config: CustomHarnessConfig?) {
        guard let config else {
            _ = KeychainService.delete("customAgentHarness")
            return
        }
        if let data = try? JSONEncoder().encode(config) {
            KeychainService.setData(data, for: "customAgentHarness")
        }
    }

    // MARK: - Codex / Claude Code remote harnesses (Plan N, Phase 3)

    /// OpenAI Codex cloud API token (Keychain — secret). Empty ⇒ harness not configured.
    static var codexAgentToken: String {
        KeychainService.string(for: "codexAgentToken") ?? ""
    }
    static func setCodexAgentToken(_ token: String) {
        if token.isEmpty { _ = KeychainService.delete("codexAgentToken") }
        else { _ = KeychainService.setString(token, for: "codexAgentToken") }
    }
    /// Optional base-URL override for the Codex endpoint (non-secret). Blank ⇒ preset default.
    static var codexAgentBaseURL: String {
        UserDefaults.standard.string(forKey: "codexAgentBaseURL") ?? ""
    }
    static func setCodexAgentBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "codexAgentBaseURL")
    }

    /// Claude Code remote API token (Keychain — secret). Empty ⇒ harness not configured.
    static var claudeRemoteToken: String {
        KeychainService.string(for: "claudeRemoteToken") ?? ""
    }
    static func setClaudeRemoteToken(_ token: String) {
        if token.isEmpty { _ = KeychainService.delete("claudeRemoteToken") }
        else { _ = KeychainService.setString(token, for: "claudeRemoteToken") }
    }
    /// Optional base-URL override for the Claude Code endpoint (non-secret). Blank ⇒ preset default.
    static var claudeRemoteBaseURL: String {
        UserDefaults.standard.string(forKey: "claudeRemoteBaseURL") ?? ""
    }
    static func setClaudeRemoteBaseURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "claudeRemoteBaseURL")
    }

    // MARK: - Field Assist (B2B)

    /// Developer-only: run the local MCP glasses HTTP server (Plan E). Only effective when
    /// `agentModeEnabled` is also on.
    @UserDefaultsBacked("mcpServerEnabled", default: false) static var mcpServerEnabled: Bool

    static func setMCPServerEnabled(_ enabled: Bool) { mcpServerEnabled = enabled }

    /// Master toggle for the Accessibility Tier (A1 Reading Accessibility). When off, the
    /// ReadingAccessibilityTool is not registered.
    @UserDefaultsBacked("accessibilityModeEnabled", default: false) static var accessibilityModeEnabled: Bool

    static func setAccessibilityModeEnabled(_ enabled: Bool) { accessibilityModeEnabled = enabled }

    /// Master toggle for fingerspelling recognition (Plan CK): the live camera →
    /// landmarks → CTC decode → speech pipeline. Off by default; the session also
    /// requires the downloaded model bundle before it can start.
    @UserDefaultsBacked("fingerspellingEnabled", default: false) static var fingerspellingEnabled: Bool

    static func setFingerspellingEnabled(_ enabled: Bool) { fingerspellingEnabled = enabled }

    /// P3 tuning knobs, runtime-adjustable so device smoke needs no rebuilds
    /// (Settings › Accessibility › Fingerspelling › Tuning). Defaults match the shipped
    /// P2 values; both are read at session start.
    /// Decode cadence in appended frames (≈ every 0.5 s at 15 fps with the default 8).
    @UserDefaultsBacked("fingerspellingDecodeEveryFrames", default: 8)
    static var fingerspellingDecodeEveryFrames: Int
    /// Confidence floor on per-row CTC observations (0 disables the floor entirely —
    /// pure greedy decode, matching the offline gate).
    @UserDefaultsBacked("fingerspellingConfidenceFloor", default: 0.5)
    static var fingerspellingConfidenceFloor: Double

    /// Master toggle for the Field Assist feature. When off, no vaults are loaded
    /// and the FieldSessionTool is not registered.
    static var fieldAssistEnabled: Bool {
        UserDefaults.standard.bool(forKey: "fieldAssistEnabled")
    }

    static func setFieldAssistEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "fieldAssistEnabled")
    }

    // MARK: - Field Assist entitlement

    /// Display mirror of the last license validation. **Not authoritative** — it is a plain mutable
    /// preference, so it is exactly as forgeable as any other. Entitlement decisions re-verify the
    /// stored license code itself; this only drives settings copy.
    static var fieldAssistLicenseValid: Bool {
        UserDefaults.standard.bool(forKey: "fieldAssistLicenseValid")
    }

    static func setFieldAssistLicenseValid(_ valid: Bool) {
        UserDefaults.standard.set(valid, forKey: "fieldAssistLicenseValid")
    }

    /// Display mirror of `StoreKitService.isFieldAssistPurchased`. **Not authoritative** for the same
    /// reason as `fieldAssistLicenseValid`; the verified transaction is the evidence.
    static var fieldAssistPurchased: Bool {
        UserDefaults.standard.bool(forKey: "fieldAssistPurchased")
    }

    static func setFieldAssistPurchased(_ purchased: Bool) {
        UserDefaults.standard.set(purchased, forKey: "fieldAssistPurchased")
    }

    /// Whether the user is entitled to Field Assist. This is the paywall; `fieldAssistEnabled` is the
    /// user's on/off switch and is only meaningful when entitled.
    ///
    /// Delegates to the entitlement evaluator, which decides from verified evidence — a StoreKit
    /// transaction verified in this process, or a signed organization license re-checked at read
    /// time. There is no stored "entitled" boolean behind this, by design.
    static var fieldAssistUnlocked: Bool {
        FieldAssistEntitlement.shared.isGranted
    }

    /// True only when Field Assist is both entitled and switched on. Field tools and vaults gate on
    /// this so a lapsed entitlement disables the feature even if the toggle was left on.
    static var fieldAssistActive: Bool {
        fieldAssistEnabled && fieldAssistUnlocked
    }

    /// Preferred vault for new Field Assist sessions (defaults to refrigeration).
    static var fieldAssistDefaultVaultId: String {
        UserDefaults.standard.string(forKey: "fieldAssistDefaultVaultId") ?? "refrigeration"
    }

    static func setFieldAssistDefaultVaultId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "fieldAssistDefaultVaultId")
    }

    // MARK: - Per-vault model linking

    /// The model a given Field Assist vault is linked to (a savedModel id). nil = use
    /// whatever the current active model is. Lets each vault carry its own model so
    /// switching vaults switches the model.
    static func fieldAssistVaultModelId(for vaultId: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: "fieldAssistVaultModels") as? [String: String] ?? [:]
        return map[vaultId]
    }

    static func setFieldAssistVaultModelId(_ modelId: String?, for vaultId: String) {
        var map = UserDefaults.standard.dictionary(forKey: "fieldAssistVaultModels") as? [String: String] ?? [:]
        if let modelId, !modelId.isEmpty {
            map[vaultId] = modelId
        } else {
            map.removeValue(forKey: vaultId)
        }
        UserDefaults.standard.set(map, forKey: "fieldAssistVaultModels")
    }

    /// Optional webhook (Slack-compatible) paged when a technician escalates to a human expert.
    /// Empty = local notification only.
    static var expertWebhookURL: String {
        UserDefaults.standard.string(forKey: "expertWebhookURL") ?? ""
    }

    static func setExpertWebhookURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "expertWebhookURL")
    }

    /// Transport used to stream the glasses view to a remote expert on escalation.
    /// Defaults to MJPEG (the shipped, working browser-viewer stream).
    static var expertStreamTransport: ExpertStreamKind {
        ExpertStreamKind(rawValue: UserDefaults.standard.string(forKey: "expertStreamTransport") ?? "mjpeg") ?? .mjpeg
    }

    static func setExpertStreamTransport(_ kind: ExpertStreamKind) {
        UserDefaults.standard.set(kind.rawValue, forKey: "expertStreamTransport")
    }

    /// External meeting URL (Zoom/Teams/Meet/Whereby) for the zero-infra "Meeting link" transport.
    static var expertMeetingURL: String {
        UserDefaults.standard.string(forKey: "expertMeetingURL") ?? ""
    }
    static func setExpertMeetingURL(_ url: String) { UserDefaults.standard.set(url, forKey: "expertMeetingURL") }

    // MARK: WebRTC transport config (Plan L)

    /// WebSocket signaling endpoint that relays SDP/ICE between the glasses app and the expert.
    /// Required for the WebRTC transport to connect.
    static var expertSignalingURL: String {
        UserDefaults.standard.string(forKey: "expertSignalingURL") ?? ""
    }
    static func setExpertSignalingURL(_ url: String) { UserDefaults.standard.set(url, forKey: "expertSignalingURL") }

    /// STUN server (host discovery). Defaults to a public Google STUN server.
    static var expertStunURL: String {
        UserDefaults.standard.string(forKey: "expertStunURL") ?? "stun:stun.l.google.com:19302"
    }
    static func setExpertStunURL(_ url: String) { UserDefaults.standard.set(url, forKey: "expertStunURL") }

    /// TURN relay (needed across NAT/cellular). Empty = STUN only.
    static var expertTurnURL: String {
        UserDefaults.standard.string(forKey: "expertTurnURL") ?? ""
    }
    static func setExpertTurnURL(_ url: String) { UserDefaults.standard.set(url, forKey: "expertTurnURL") }

    static var expertTurnUsername: String {
        UserDefaults.standard.string(forKey: "expertTurnUsername") ?? ""
    }
    static func setExpertTurnUsername(_ v: String) { UserDefaults.standard.set(v, forKey: "expertTurnUsername") }

    /// TURN server credential (a password). Stored in the Keychain (see `KeychainService`).
    static var expertTurnCredential: String {
        KeychainService.string(for: "expertTurnCredential") ?? ""
    }
    static func setExpertTurnCredential(_ v: String) { KeychainService.setString(v, for: "expertTurnCredential") }

    /// Default session mode for Field Assist ("ai_only" or "human_assisted").
    /// Human-assisted requires Phase 5 work to ship; UI should grey it out until then.
    static var fieldAssistDefaultMode: String {
        UserDefaults.standard.string(forKey: "fieldAssistDefaultMode") ?? "ai_only"
    }

    static func setFieldAssistDefaultMode(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "fieldAssistDefaultMode")
    }

    // MARK: - Agent Check Intervals

    /// How often the agent checks for tasks when glasses are connected (minutes).
    static var agentConnectedInterval: Int {
        let val = UserDefaults.standard.integer(forKey: "agentConnectedInterval")
        return val > 0 ? val : 5
    }
    static func setAgentConnectedInterval(_ minutes: Int) {
        UserDefaults.standard.set(max(1, minutes), forKey: "agentConnectedInterval")
    }

    /// How often the agent checks for tasks when glasses are disconnected (minutes).
    static var agentDisconnectedInterval: Int {
        let val = UserDefaults.standard.integer(forKey: "agentDisconnectedInterval")
        return val > 0 ? val : 30
    }
    static func setAgentDisconnectedInterval(_ minutes: Int) {
        UserDefaults.standard.set(max(5, minutes), forKey: "agentDisconnectedInterval")
    }

    // MARK: - Agent Chattiness

    /// How proactive the agent is: quiet (only when asked), normal (scheduled + relevant),
    /// chatty (proactive observations + suggestions).
    enum AgentChattiness: String, CaseIterable, Identifiable {
        case quiet, normal, chatty

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .quiet: return "Quiet"
            case .normal: return "Normal"
            case .chatty: return "Chatty"
            }
        }

        var description: String {
            switch self {
            case .quiet: return "Only responds when asked. Scheduled tasks run silently."
            case .normal: return "Speaks scheduled results and important notifications."
            case .chatty: return "Proactive observations, suggestions, and commentary."
            }
        }

        var icon: String {
            switch self {
            case .quiet: return "speaker.slash"
            case .normal: return "speaker.wave.2"
            case .chatty: return "speaker.wave.3"
            }
        }
    }

    static var agentChattiness: AgentChattiness {
        AgentChattiness(rawValue: UserDefaults.standard.string(forKey: "agentChattiness") ?? "") ?? .normal
    }
    static func setAgentChattiness(_ level: AgentChattiness) {
        UserDefaults.standard.set(level.rawValue, forKey: "agentChattiness")
    }

    /// Whether the agent has completed its initial onboarding questions.
    @UserDefaultsBacked("agentOnboardingComplete", default: false) static var agentOnboardingComplete: Bool

    static func setAgentOnboardingComplete(_ complete: Bool) { agentOnboardingComplete = complete }

    // MARK: - Conversation Persistence

    static var conversationPersistenceEnabled: Bool {
        let key = "conversationPersistenceEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return true // Default enabled
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setConversationPersistenceEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "conversationPersistenceEnabled")
    }

    // MARK: - Conversation Encryption

    static var conversationEncryptionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "conversationEncryptionEnabled")
    }

    static func setConversationEncryptionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "conversationEncryptionEnabled")
    }

    // MARK: - Disabled Tools

    static var disabledTools: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "disabledTools") ?? [])
    }

    static func setDisabledTools(_ tools: Set<String>) {
        UserDefaults.standard.set(Array(tools), forKey: "disabledTools")
    }

    static func isToolEnabled(_ name: String) -> Bool {
        !disabledTools.contains(name)
    }

    static func setToolEnabled(_ name: String, enabled: Bool) {
        var disabled = disabledTools
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        setDisabledTools(disabled)
    }

    // MARK: - Offline Mode

    /// Tools that require an internet connection (excluding LLM which is always needed).
    static let internetRequiringTools: Set<String> = [
        "get_weather", "web_search", "get_news", "convert_currency",
        "identify_song", "translate", "define_word", "daily_briefing",
        "find_nearby", "get_directions", "openclaw_skills"
    ]

    static var offlineModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "offlineModeEnabled")
    }

    static func setOfflineModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "offlineModeEnabled")
        var disabled = disabledTools
        if enabled {
            disabled.formUnion(internetRequiringTools)
        } else {
            disabled.subtract(internetRequiringTools)
        }
        setDisabledTools(disabled)
    }

    // MARK: - Local Model Roles

    /// Preferred local model for text conversation (e.g. "mlx-community/Qwen2.5-3B-Instruct-4bit").
    static var localTextModelId: String {
        UserDefaults.standard.string(forKey: "localTextModelId") ?? ""
    }

    static func setLocalTextModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "localTextModelId")
    }

    /// Preferred local model for vision/photo tasks (e.g. "mlx-community/SmolVLM2-2.2B-Instruct-mlx").
    static var localVisionModelId: String {
        UserDefaults.standard.string(forKey: "localVisionModelId") ?? ""
    }

    static func setLocalVisionModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "localVisionModelId")
    }

    // MARK: - Agent Model

    /// On-device agent model ID (Gemma 4 E2B by default).
    static let defaultAgentModelId = "mlx-community/gemma-4-e2b-it-4bit"

    static var agentModelId: String {
        UserDefaults.standard.string(forKey: "agentModelId") ?? defaultAgentModelId
    }

    static func setAgentModelId(_ id: String) {
        UserDefaults.standard.set(id, forKey: "agentModelId")
    }

    /// Whether the on-device agent model has been downloaded.
    @UserDefaultsBacked("agentModelDownloaded", default: false) static var agentModelDownloaded: Bool

    static func setAgentModelDownloaded(_ value: Bool) { agentModelDownloaded = value }

    /// Whether fast-tier queries may run on the *on-device* MLX agent model.
    ///
    /// Historically default-off because the gemma-4 agent model fatally crashed during
    /// inference: the VLM factory could not map its weights, and the fallbacks around that
    /// failure were where the crashes lived. The upstream load fix is now pinned (see
    /// `project.base.yml`), but the default stays off pending on-device confirmation that a
    /// full turn generates cleanly. Cloud agents are unaffected.
    @UserDefaultsBacked("localAgentEnabled", default: false) static var localAgentEnabled: Bool

    static func setLocalAgentEnabled(_ value: Bool) { localAgentEnabled = value }
}

import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @AppStorage("accentColorName") private var accentColorName: String = "violet"

    // Model configs editing
    @State private var modelConfigs: [ModelConfig] = Config.savedModels
    @State private var editingModel: ModelConfig? = nil
    @State private var showAddModel = false

    // Intelligence settings
    @State private var intentClassifierEnabled = Config.intentClassifierEnabled
    @State private var userMemoryEnabled = Config.userMemoryEnabled
    @State private var conversationPersistenceEnabled = Config.conversationPersistenceEnabled
    @State private var autoModelRoutingEnabled = Config.autoModelRoutingEnabled

    // Privacy filter
    @State private var privacyFilterEnabled = Config.privacyFilterEnabled
    @State private var useGlassesMicForWakeWord = Config.useGlassesMicForWakeWord

    // Security
    @State private var conversationEncryptionEnabled = Config.conversationEncryptionEnabled
    @State private var isTogglingEncryption = false

    // Service settings (owned here, bound to ServicesSettingsView)
    @State private var elevenLabsKeyInput = Config.elevenLabsAPIKey
    @State private var selectedVoice = Config.elevenLabsVoiceId
    @State private var emotionAwareTTSEnabled = Config.emotionAwareTTSEnabled
    @State private var perplexityKeyInput = Config.perplexityAPIKey
    @State private var broadcastPlatform = Config.broadcastPlatform
    @State private var broadcastRTMPURL = Config.broadcastRTMPURL
    @State private var broadcastStreamKey = Config.broadcastStreamKey

    var body: some View {
        Form {
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Core
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            // MARK: Wake Word
            Section {
                Picker("Wake Phrase", selection: Binding(
                    get: { Config.wakePhrase },
                    set: { newValue in
                        Config.setWakePhrase(newValue)
                        Config.setAlternativeWakePhrases(Config.defaultAlternativesForPhrase(newValue))
                    }
                )) {
                    Text("Hey OpenGlasses").tag("hey openglasses")
                    Text("Hey Claude").tag("hey claude")
                    Text("Hey Jarvis").tag("hey jarvis")
                    Text("Hey Computer").tag("hey computer")
                    Text("Hey Assistant").tag("hey assistant")
                    Text("Hey Rayban").tag("hey rayban")
                }

                InfoToggle(
                    title: "Silent Mode",
                    isOn: Binding(
                        get: { Config.silentMode },
                        set: { newValue in
                            Config.setSilentMode(newValue)
                            if newValue {
                                appState.wakeWordService.stopListening()
                                appState.isListening = false
                            } else {
                                Task { try? await appState.wakeWordService.startListening() }
                            }
                        }
                    ),
                    info: "Turns off the always-listening wake word detector. The assistant is still fully functional via the Apple Watch, home screen widget, Action Button, and manual mic tap. Useful in meetings or quiet environments."
                )
            } header: {
                Text("Voice")
            } footer: {
                Text("The phrase that starts a conversation. Silent Mode keeps the assistant fully available via widget, watch, and Action Button — just without the always-listening mic.")
            }

            // MARK: AI Models
            Section {
                ForEach(modelConfigs) { model in
                    Button {
                        editingModel = model
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .foregroundStyle(Color(.label))
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(model.llmProvider.displayName)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if model.visionEnabled {
                                        Image(systemName: "eye")
                                            .font(.caption2)
                                            .foregroundStyle(Color(.label))
                                            .accessibilityLabel("Vision enabled")
                                    }
                                    if !model.apiKey.isEmpty {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                            .accessibilityLabel("API key set")
                                    } else {
                                        Image(systemName: "exclamationmark.circle")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("API key missing")
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.name), \(model.llmProvider.displayName)\(!model.apiKey.isEmpty ? "" : ", API key missing")\(model.visionEnabled ? ", vision enabled" : "")")
                    .accessibilityHint("Double-tap to edit")
                }
                .onDelete { indexSet in
                    modelConfigs.remove(atOffsets: indexSet)
                }

                Button {
                    showAddModel = true
                } label: {
                    Label("Add Model", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("AI Models")
            } footer: {
                Text("Models are the AI you talk to. Add a key for any provider you want — you can switch between them anytime from the main screen.")
            }

            // MARK: Personality
            Section {
                NavigationLink {
                    PersonasView()
                } label: {
                    HStack {
                        Label("Personas", systemImage: "person.2")
                        Spacer()
                        Text("\(Config.enabledPersonas.count) active")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    PromptPresetsView()
                } label: {
                    HStack {
                        Label("System Prompt", systemImage: "text.quote")
                        Spacer()
                        Text(Config.activePreset?.name ?? "Default")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Personality")
            } footer: {
                Text("Personas are different characters with their own model + prompt (e.g. a museum docent, a fitness coach). System Prompt tweaks the default voice and behaviour.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Intelligence
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                InfoToggle(
                    title: "Intent Classifier",
                    isOn: $intentClassifierEnabled,
                    info: "Uses a lightweight on-device model to determine if speech is directed at the assistant or is just background conversation. Prevents the AI from responding to nearby chatter, TV audio, or other people talking."
                )
                InfoToggle(
                    title: "User Memory",
                    isOn: $userMemoryEnabled,
                    info: "Remembers facts you share across conversations — your name, preferences, routines, dietary needs, etc. This context is included in future conversations so the AI can personalise responses. Memory is stored locally on your device."
                )
                InfoToggle(
                    title: "Conversation History",
                    isOn: $conversationPersistenceEnabled,
                    info: "Saves conversation transcripts so you can review them later in the History tab. Also provides context for follow-up questions within a session. When off, conversations are ephemeral and discarded after each session."
                )

                NavigationLink {
                    SmartRoutingView(
                        autoModelRoutingEnabled: $autoModelRoutingEnabled,
                        modelConfigs: modelConfigs
                    )
                } label: {
                    HStack {
                        Label("Smart Routing", systemImage: "arrow.triangle.branch")
                        Spacer()
                        Text(autoModelRoutingEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    AgenticFeaturesView(agentDocs: appState.agentDocs, localLLM: appState.localLLMService)
                        .environmentObject(appState)
                } label: {
                    HStack {
                        Label("Agentic Features", systemImage: "bolt.badge.automatic")
                        Spacer()
                        if Config.agentModeEnabled {
                            Text("On")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("How It Behaves")
            } footer: {
                Text("Intent Classifier ignores nearby chatter so the AI only responds when you're talking to it. Memory and History let the AI remember who you are across sessions. Smart Routing picks the right model for the task; Agentic Features let the AI take multi-step actions on its own.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Privacy & Compliance
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            // (Medical Compliance moved into "Glasses & Privacy" below.)

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Tools & Actions
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                NavigationLink {
                    QuickActionsSettingsView()
                } label: {
                    Label("Quick Actions", systemImage: "dial.high")
                }

                NavigationLink {
                    ToolsSettingsView(appState: appState)
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }

                NavigationLink {
                    FieldAssistSettingsView()
                } label: {
                    HStack {
                        Label("Field Assist", systemImage: "wrench.adjustable")
                        Spacer()
                        if Config.fieldAssistEnabled {
                            Text("On").foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    VaultManagerView()
                } label: {
                    Label("Custom Vaults", systemImage: "tray.full")
                }

                NavigationLink {
                    VaultFilesEditorView(vaultId: "notes", title: "Personal Notes")
                } label: {
                    Label("Personal Notes", systemImage: "note.text")
                }

                NavigationLink {
                    HealthVaultEditorView()
                } label: {
                    HStack {
                        Label("Health Vault", systemImage: "heart.text.square")
                        Spacer()
                        if VaultRegistry.shared.isUnlocked("health") {
                            Text("Unlocked").foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    AccessibilitySettingsView()
                        .environmentObject(appState)
                } label: {
                    HStack {
                        Label("Accessibility", systemImage: "accessibility")
                        Spacer()
                        if Config.accessibilityModeEnabled {
                            Text("On").foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    CustomToolsView()
                        .environmentObject(appState)
                } label: {
                    Label("Custom Tools", systemImage: "hammer")
                }

                if Config.agentModeEnabled {
                    NavigationLink {
                        MCPServerSettingsView()
                            .environmentObject(appState)
                    } label: {
                        HStack {
                            Label("MCP Server", systemImage: "macbook.and.iphone")
                            Spacer()
                            if MCPGlassesServer.shared.isRunning {
                                Text("Running").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                NavigationLink {
                    PlaybooksSettingsView(store: appState.playbookStore)
                } label: {
                    Label("Playbooks", systemImage: "list.clipboard")
                }

                NavigationLink {
                    ClawHubBrowserView()
                } label: {
                    HStack {
                        Label("Skill Store", systemImage: "square.grid.3x3.square")
                        Spacer()
                        let count = InstalledSkillStore.shared.installedSkills.filter(\.enabled).count
                        if count > 0 {
                            Text("\(count) active")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Tools the AI Can Use")
            } footer: {
                Text("Quick Actions are shortcuts you can tap from the widget. Tools are built-in capabilities (camera, search, HomeKit, music…). Custom Tools and Playbooks let you script your own. The Skill Store adds community-built skills.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Connections
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                NavigationLink {
                    ServicesSettingsView(
                        appState: appState,
                        elevenLabsKeyInput: $elevenLabsKeyInput,
                        selectedVoice: $selectedVoice,
                        emotionAwareTTSEnabled: $emotionAwareTTSEnabled,
                        perplexityKeyInput: $perplexityKeyInput,
                        broadcastPlatform: $broadcastPlatform,
                        broadcastRTMPURL: $broadcastRTMPURL,
                        broadcastStreamKey: $broadcastStreamKey
                    )
                } label: {
                    Label("Services & Integrations", systemImage: "square.grid.2x2")
                }

                NavigationLink {
                    GatewaySettingsView(appState: appState)
                } label: {
                    HStack {
                        Label("Gateways", systemImage: "server.rack")
                        Spacer()
                        let count = Config.enabledGateways.count
                        if count > 0 {
                            Text("\(count) active")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    MCPServersView()
                        .environmentObject(appState)
                } label: {
                    Label("MCP Servers", systemImage: "point.3.connected.trianglepath.dotted")
                }
            } header: {
                Text("Connected Apps & Services")
            } footer: {
                Text("ElevenLabs voices, Perplexity search, broadcast targets, and live-streaming live under Services. Gateways are OpenClaw bridges to your devices (smart home, automations). MCP Servers expose external tool servers the AI can call.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Glasses & Privacy
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                NavigationLink {
                    HardwarePrivacyView(
                        appState: appState,
                        useGlassesMicForWakeWord: $useGlassesMicForWakeWord,
                        privacyFilterEnabled: $privacyFilterEnabled,
                        conversationEncryptionEnabled: $conversationEncryptionEnabled,
                        isTogglingEncryption: $isTogglingEncryption
                    )
                } label: {
                    Label("Hardware & Privacy", systemImage: "lock.shield")
                }

                NavigationLink {
                    MedicalCompliancePaywallView(
                        hipaaService: appState.hipaaService,
                        exportService: appState.medicalExportService
                    )
                } label: {
                    HStack {
                        Label("Medical Compliance", systemImage: "cross.case.fill")
                        Spacer()
                        if StoreKitService.shared.canAccessMedicalCompliance && Config.hipaaMode {
                            Image(systemName: "cross.case.fill")
                                .font(.caption)
                                .foregroundStyle(AppAccent.aiCoral)
                                .accessibilityHidden(true)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .accessibilityLabel("Active")
                        } else if !StoreKitService.shared.canAccessMedicalCompliance {
                            Image(systemName: "cross.case.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } header: {
                Text("Glasses & Privacy")
            } footer: {
                Text("Mic source, on-device bystander-face blurring, and encrypted conversations live in Hardware & Privacy. Medical Compliance enables HIPAA-grade encryption and exports for clinical use (separate subscription).")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Appearance
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                Picker("Theme", selection: Binding(
                    get: { UserDefaults.standard.string(forKey: "appAppearance") ?? "dark" },
                    set: { UserDefaults.standard.set($0, forKey: "appAppearance") }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("System").tag("system")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Accent Colour")
                        .font(.subheadline)
                    HStack(spacing: 12) {
                        ForEach(AppAccent.presets) { preset in
                            Button {
                                accentColorName = preset.id
                                Config.setAccentColorName(preset.id)
                            } label: {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white, lineWidth: accentColorName == preset.id ? 2.5 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(preset.name) accent colour\(accentColorName == preset.id ? ", selected" : "")")
                        }
                    }
                }
                .padding(.vertical, 4)

                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    HStack {
                        Label("Languages", systemImage: "globe")
                        Spacer()
                        let downloaded = LocalizationManager.shared.downloadableLanguages.filter(\.isDownloaded).count
                        let bundled = LocalizationManager.bundledLanguages.count
                        Text("\(bundled + downloaded) available")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Look & Feel")
            } footer: {
                Text("Theme, accent colour, and which languages the assistant speaks and understands.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — Advanced
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                NavigationLink {
                    PromptInspectorView(appState: appState)
                } label: {
                    Label("Prompt Inspector", systemImage: "doc.text.magnifyingglass")
                }

                NavigationLink {
                    NetworkMonitorView()
                } label: {
                    Label("Network Activity", systemImage: "antenna.radiowaves.left.and.right")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Diagnostic tools for power users — inspect the prompts being sent to the AI and watch live network requests. Useful for debugging or building your own integrations.")
            }

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // MARK: — About
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

            Section {
                HStack {
                    Label("Version", systemImage: "info.circle")
                    Spacer()
                    Text(Self.appVersion)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Build", systemImage: "hammer")
                    Spacer()
                    Text(Self.buildNumber)
                        .foregroundStyle(.secondary)
                }

                Button {
                    let webURL = URL(string: "https://discord.gg/8W2qaXJzz9")!
                    UIApplication.shared.open(webURL)
                } label: {
                    HStack {
                        Label("Discord", systemImage: "bubble.left.and.bubble.right")
                        Spacer()
                        Text("OpenGlasses Discord")
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(Color(.label))
            } header: {
                Text("About")
            } footer: {
                Text("OpenGlasses is an open-source community project. Join the Discord for help, ideas, and to share what you've built.")
            }
        }
        .navigationTitle("Settings")
        .tint(accent)
        .sheet(item: $editingModel) { model in
            ModelEditorView(model: model) { updated in
                if let idx = modelConfigs.firstIndex(where: { $0.id == updated.id }) {
                    modelConfigs[idx] = updated
                    Config.setSavedModels(modelConfigs)
                }
            }
        }
        .sheet(isPresented: $showAddModel) {
            AddModelView { newModel in
                modelConfigs.append(newModel)
                Config.setSavedModels(modelConfigs)
            }
        }
        .onDisappear {
            saveSettings()
        }
    }

    // MARK: - Voice Isolation

    /// Shows Apple's system Voice Isolation / Mic Modes picker.
    /// Enables noise cancellation for use in noisy environments.
    private func showVoiceIsolationPicker() {
        #if !targetEnvironment(simulator)
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        #endif
    }

    // MARK: - About

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    // MARK: - Save Settings

    private func saveSettings() {
        Config.setSavedModels(modelConfigs)

        if !modelConfigs.contains(where: { $0.id == Config.activeModelId }) {
            if let first = modelConfigs.first {
                Config.setActiveModelId(first.id)
            }
        }
        appState.llmService.refreshActiveModel()

        Config.setElevenLabsAPIKey(elevenLabsKeyInput)
        Config.setElevenLabsVoiceId(selectedVoice)
        // Reset quota cache in case user added credits or changed key
        appState.speechService.resetElevenLabsQuota()

        Config.setPerplexityAPIKey(perplexityKeyInput)
        Config.setPrivacyFilterEnabled(privacyFilterEnabled)
        appState.privacyFilter.isEnabled = privacyFilterEnabled
        Config.setUseGlassesMicForWakeWord(useGlassesMicForWakeWord)

        Config.setEmotionAwareTTSEnabled(emotionAwareTTSEnabled)

        Config.setIntentClassifierEnabled(intentClassifierEnabled)
        Config.setUserMemoryEnabled(userMemoryEnabled)
        Config.setConversationPersistenceEnabled(conversationPersistenceEnabled)

        Config.setBroadcastPlatform(broadcastPlatform)
        Config.setBroadcastRTMPURL(broadcastRTMPURL)
        Config.setBroadcastStreamKey(broadcastStreamKey)

        if appState.currentMode == .direct {
            Task {
                appState.wakeWordService.stopListening()
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? await appState.wakeWordService.startListening()
            }
        }
    }
}

// MARK: - Tier Model Picker

/// Lets the user assign a specific model to a complexity tier for smart routing.
struct TierModelPicker: View {
    let tier: Config.ModelTier
    let models: [ModelConfig]

    @State private var selectedModelId: String

    init(tier: Config.ModelTier, models: [ModelConfig]) {
        self.tier = tier
        self.models = models
        _selectedModelId = State(initialValue: Config.modelIdForTier(tier) ?? "")
    }

    private var selectedModelName: String {
        if selectedModelId.isEmpty { return "Auto" }
        guard let model = models.first(where: { $0.id == selectedModelId }) else { return "Auto" }
        return model.model.isEmpty ? model.name : model.model
    }

    var body: some View {
        NavigationLink {
            TierModelDetailPicker(
                tier: tier,
                models: models,
                selectedModelId: $selectedModelId
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tier.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.displayName)
                    Text(tier.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectedModelName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onChange(of: selectedModelId) { _, newValue in
            Config.setModelForTier(tier, modelId: newValue.isEmpty ? nil : newValue)
        }
    }
}

/// Detail picker for selecting a specific model for a routing tier.
/// Groups saved models by provider and fetches all available models from each provider's API.
struct TierModelDetailPicker: View {
    let tier: Config.ModelTier
    let models: [ModelConfig]
    @Binding var selectedModelId: String

    /// Unique providers from saved models (all providers, not just those with API keys).
    private var providers: [(config: ModelConfig, provider: LLMProvider)] {
        var seen = Set<String>()
        return models.compactMap { model in
            guard seen.insert(model.provider).inserted else { return nil }
            return (config: model, provider: model.llmProvider)
        }.sorted { $0.provider.displayName < $1.provider.displayName }
    }

    /// The currently selected model ID — could be a saved ModelConfig.id or a "provider:modelId" composite.
    private var currentSelection: String {
        if selectedModelId.isEmpty { return "" }
        // Check if it's a saved model
        if let model = models.first(where: { $0.id == selectedModelId }) {
            return model.model
        }
        // It's a provider:modelId composite — extract the model part
        if let range = selectedModelId.range(of: "::") {
            return String(selectedModelId[range.upperBound...])
        }
        return selectedModelId
    }

    var body: some View {
        List {
            Section {
                selectionRow(label: "Auto-detect", isSelected: selectedModelId.isEmpty) {
                    selectedModelId = ""
                }
            } footer: {
                Text("Automatically selects the best available model for \(tier.displayName.lowercased()) requests.")
            }

            ForEach(providers, id: \.provider) { entry in
                TierProviderSection(
                    config: entry.config,
                    provider: entry.provider,
                    selectedModelId: $selectedModelId
                )
            }
        }
        .navigationTitle(tier.displayName)
    }

    private func selectionRow(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
        }
        .foregroundStyle(Color(.label))
    }
}

/// A section within the tier picker showing all available models for one provider.
private struct TierProviderSection: View {
    let config: ModelConfig
    let provider: LLMProvider
    @Binding var selectedModelId: String

    @State private var availableModels: [ModelFetcher.RemoteModel] = []
    @State private var isFetching = false
    @State private var hasFetched = false

    /// Always read live from Config so newly created models are visible.
    private var allModels: [ModelConfig] { Config.savedModels }

    var body: some View {
        Section {
            if isFetching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models…")
                        .foregroundStyle(.secondary)
                }
            } else if availableModels.isEmpty && hasFetched {
                // Fallback: show the saved model(s) for this provider
                ForEach(allModels.filter({ $0.provider == provider.rawValue })) { model in
                    modelRow(id: model.model, name: model.model, configId: model.id)
                }
            } else {
                ForEach(availableModels) { remote in
                    modelRow(id: remote.id, name: remote.name, configId: nil)
                }
            }
        } header: {
            Text(provider.displayName)
        }
        .task {
            guard !hasFetched else { return }
            isFetching = true
            availableModels = await ModelFetcher.fetchModels(
                provider: provider,
                apiKey: config.apiKey,
                baseURL: config.baseURL
            )
            hasFetched = true
            isFetching = false
        }
    }

    /// Check if a given model ID is currently selected for this provider.
    private func isSelected(_ modelId: String, configId: String?) -> Bool {
        // Direct match on saved model config ID
        if let cid = configId, selectedModelId == cid { return true }
        // Match on composite key
        if selectedModelId == "\(provider.rawValue)::\(modelId)" { return true }
        // Match if a saved model with this model ID is selected
        if let selected = allModels.first(where: { $0.id == selectedModelId }),
           selected.model == modelId { return true }
        return false
    }

    private func modelRow(id: String, name: String, configId: String?) -> some View {
        Button {
            // Prefer selecting via saved ModelConfig if one exists with this model ID
            if let existing = allModels.first(where: { $0.provider == provider.rawValue && $0.model == id }) {
                selectedModelId = existing.id
            } else {
                // Create or update a ModelConfig for this provider+model and select it
                selectRemoteModel(id: id, name: name)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .lineLimit(1)
                    if name != id {
                        Text(id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected(id, configId: configId) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                }
            }
        }
        .foregroundStyle(Color(.label))
    }

    /// When user picks a model that doesn't have a saved ModelConfig, create one
    /// using the same API key and base URL from the existing config for this provider.
    private func selectRemoteModel(id: String, name: String) {
        let newConfig = ModelConfig(
            id: UUID().uuidString,
            name: "\(provider.displayName) — \(name)",
            provider: provider.rawValue,
            apiKey: config.apiKey,
            model: id,
            baseURL: config.baseURL
        )
        var saved = Config.savedModels
        saved.append(newConfig)
        Config.setSavedModels(saved)
        selectedModelId = newConfig.id
    }
}

// MARK: - Smart Routing Sub-View

struct SmartRoutingView: View {
    @Binding var autoModelRoutingEnabled: Bool
    let modelConfigs: [ModelConfig]

    var body: some View {
        Form {
            Section {
                InfoToggle(
                    title: "Auto Model Routing",
                    isOn: $autoModelRoutingEnabled,
                    info: "Automatically classifies each request by complexity and routes it to the right model. Simple queries like \"what time is it\" use a fast, cheap model. Complex reasoning uses your best model. Saves cost without sacrificing quality. Assign models to each tier below."
                )
                .onChange(of: autoModelRoutingEnabled) { _, newValue in
                    Config.setAutoModelRoutingEnabled(newValue)
                }
            } footer: {
                Text(autoModelRoutingEnabled
                     ? "Requests are classified by complexity and routed to the assigned model. Memory and conversation context are always preserved."
                     : "When enabled, simple requests use a faster model while complex questions use your best model."
                )
            }

            if autoModelRoutingEnabled {
                Section {
                    ForEach(Config.ModelTier.allCases) { tier in
                        TierModelPicker(tier: tier, models: modelConfigs)
                    }
                } header: {
                    Text("Tier Assignments")
                } footer: {
                    Text("Assign any model to each tier. Simple queries use Fast, most use Balanced, complex reasoning uses Best.")
                }
            }
        }
        .navigationTitle("Smart Routing")
    }
}

// MARK: - Hardware & Privacy Sub-View

struct HardwarePrivacyView: View {
    @ObservedObject var appState: AppState
    @Binding var useGlassesMicForWakeWord: Bool
    @Binding var privacyFilterEnabled: Bool
    @Binding var conversationEncryptionEnabled: Bool
    @Binding var isTogglingEncryption: Bool
    @State private var showEncryptionInfo = false

    var body: some View {
        Form {
            Section {
                InfoToggle(
                    title: "Listen via Glasses Mic",
                    isOn: $useGlassesMicForWakeWord,
                    info: "Routes the wake word listener through the glasses' Bluetooth microphone instead of the phone mic. Enables true hands-free use — say the wake phrase without touching your phone. Uses more battery due to continuous Bluetooth audio streaming."
                )
                InfoToggle(
                    title: "Audio-Only Mode",
                    isOn: Binding(
                        get: { Config.audioOnlyMode },
                        set: { Config.setAudioOnlyMode($0) }
                    ),
                    info: "Disables camera video streaming from the glasses. Voice commands still work but vision features (photo capture, live video analysis) are unavailable. Significantly extends glasses battery life."
                )
                InfoToggle(
                    title: "Use Phone Mic for Translation",
                    isOn: Binding(
                        get: { Config.usePhoneMicForTranslation },
                        set: { Config.setUsePhoneMicForTranslation($0) }
                    ),
                    info: "Uses the phone's microphone instead of the glasses mic for live translation. Useful when holding the phone near the person speaking a foreign language, or when the glasses mic has too much background noise."
                )
                InfoToggle(
                    title: "Glasses Only Audio",
                    isOn: Binding(
                        get: { Config.glassesOnlyAudio },
                        set: { Config.setGlassesOnlyAudio($0) }
                    ),
                    info: "When on, the agent and notification sounds are silent if your glasses aren't connected. When off (default), audio plays through the phone speaker even without glasses."
                )
                Button {
                    #if !targetEnvironment(simulator)
                    AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                    #endif
                } label: {
                    Label("Voice Isolation Mode", systemImage: "waveform.badge.mic")
                }
            } header: {
                Text("Hardware")
            } footer: {
                Text("Where the mic listens and how audio is routed. Tap any \(Image(systemName: "info.circle")) for a full explanation. Glasses mic uses more battery but is truly hands-free.")
            }

            Section {
                InfoToggle(
                    title: "Blur Bystander Faces",
                    isOn: $privacyFilterEnabled,
                    info: "Uses Apple's on-device Vision framework to detect faces in the glasses camera feed and applies a Gaussian blur to bystanders. Protects the privacy of people around you during streaming or recording. Processing happens entirely on-device."
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Bystander Face Blur runs entirely on-device — no images leave your phone.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { conversationEncryptionEnabled },
                    set: { newValue in
                        guard !isTogglingEncryption else { return }
                        isTogglingEncryption = true
                        Task {
                            if newValue {
                                let success = await appState.conversationStore.enableEncryption()
                                await MainActor.run { conversationEncryptionEnabled = success }
                            } else {
                                let success = await appState.conversationStore.disableEncryption()
                                await MainActor.run { conversationEncryptionEnabled = !success }
                            }
                            await MainActor.run { isTogglingEncryption = false }
                        }
                    }
                )) {
                    HStack(spacing: 6) {
                        Text("Encrypt Conversations")
                        Button { showEncryptionInfo = true } label: {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        if isTogglingEncryption {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }
                .disabled(isTogglingEncryption)
            } header: {
                Text("Security")
            } footer: {
                Text("Locks saved conversation transcripts behind Face ID / passcode. The key lives in the Secure Enclave and never leaves your device.")
            }
            .alert("Encrypt Conversations", isPresented: $showEncryptionInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Encrypts all saved conversation transcripts using ChaCha20-Poly1305 authenticated encryption. The encryption key is stored in the Secure Enclave via Keychain and requires Face ID, Touch ID, or your device passcode to unlock. Conversations are automatically locked when the app moves to the background.")
            }
        }
        .navigationTitle("Hardware & Privacy")
    }
}

// MARK: - Info Toggle

/// A toggle with an info button that shows an explanation popover.
struct InfoToggle: View {
    let title: String
    @Binding var isOn: Bool
    let info: String

    @State private var showInfo = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title)
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .alert(title, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(info)
        }
    }
}

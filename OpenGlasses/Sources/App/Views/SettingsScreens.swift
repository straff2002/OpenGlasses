import SwiftUI

// MARK: - Voice & Triggers

/// Wake word + hands-free trigger settings (always visible, including Simple Mode).
struct VoiceTriggersSettingsScreen: View {
    @ObservedObject var appState: AppState
    @AppStorage("wakePhrase") private var wakePhrase = "openglasses"

    var body: some View {
        Form {
            // MARK: Wake Word
            Section {
                Picker("Wake Phrase", selection: Binding(
                    get: { wakePhrase.isEmpty ? "openglasses" : wakePhrase },
                    set: { newValue in
                        Config.setWakePhrase(newValue)
                        Config.setAlternativeWakePhrases(Config.defaultAlternativesForPhrase(newValue))
                    }
                )) {
                    Text("OpenGlasses").tag("openglasses")
                    Text("Hey OpenGlasses").tag("hey openglasses")
                    Text("Hey Claude").tag("hey claude")
                    Text("Hey Jarvis").tag("hey jarvis")
                    Text("Hey Computer").tag("hey computer")
                    Text("Hey Assistant").tag("hey assistant")
                    Text("Hey Rayban").tag("hey rayban")
                }

                InfoToggle(
                    title: "Push-to-Talk Mode",
                    isOn: Binding(
                        get: { Config.silentMode },
                        set: { appState.setPushToTalk($0) }
                    ),
                    info: "Turns off the always-on wake-word listener so the mic isn't held in the background — fixes conflicts with music/podcasts playing at the same time. Start a conversation on demand instead: the iPhone Action Button (\"Ask OpenGlasses\"), Siri, the home screen widget, the Apple Watch, or a manual mic tap."
                )

                InfoToggle(
                    title: "Open App for Siri Questions",
                    isOn: Binding(
                        get: { Config.siriAskOpensApp },
                        set: { Config.setSiriAskOpensApp($0) }
                    ),
                    info: "When you say \"Hey Siri, ask OpenGlasses…\", the answer is normally spoken hands-free without opening the app. Turn this on if Siri says OpenGlasses isn't running — it launches the app first so the question always goes through, at the cost of bringing the app to the foreground."
                )
            } header: {
                Text("Voice")
            } footer: {
                Text("The phrase that starts a conversation. Push-to-Talk Mode stops the always-listening mic (so it won't fight other audio) — trigger on demand via the Action Button, Siri, widget, or watch.")
            }

            // MARK: Hands-Free Triggers
            Section {
                ForEach(AlternativeTrigger.allCases) { trigger in
                    InfoToggle(
                        title: trigger.displayName,
                        isOn: Binding(
                            get: { Config.alternativeTriggerEnabled(trigger) },
                            set: { newValue in
                                Config.setAlternativeTriggerEnabled(trigger, newValue)
                                appState.alternativeTriggers.refresh()
                            }
                        ),
                        info: trigger.detail
                    )
                }
                InfoToggle(
                    title: "Temple Tap (Experimental)",
                    isOn: Binding(
                        get: { Config.mediaTriggerEnabled },
                        set: { newValue in
                            Config.setMediaTriggerEnabled(newValue)
                            appState.mediaTrigger.refresh()
                        }
                    ),
                    info: "Double-tap the glasses temple (the next-track gesture) to start the assistant — no wake word needed. Works by holding the Now Playing session while nothing is playing, so it automatically steps aside whenever your own music or podcasts play."
                )
            } header: {
                Text("Hands-Free Triggers")
            } footer: {
                Text("Alternative ways to start the assistant without the wake word — for noisy, silent, or no-speech situations. All are off by default. The Volume Button trigger can interfere with normal volume control; Temple Tap pauses while your own audio plays.")
            }
        }
        .navigationTitle("Voice & Triggers")
        .ogFormStyle()
    }
}

// MARK: - AI & Personality

/// Models, personas, system prompt, and behaviour settings (owner-only; hidden in Simple Mode).
struct AIPersonalitySettingsScreen: View {
    @ObservedObject var appState: AppState
    @AppStorage("activePromptPresetId") private var activePresetId = "preset-default"
    @AppStorage("savedPersonas") private var savedPersonasData = Data()

    // Model configs editing
    @State private var modelConfigs: [ModelConfig] = Config.savedModels
    @State private var editingModel: ModelConfig? = nil
    @State private var showAddModel = false

    // Intelligence settings
    @State private var intentClassifierEnabled = Config.intentClassifierEnabled
    @State private var userMemoryEnabled = Config.userMemoryEnabled
    @State private var memoryNudgesEnabled = Config.memoryNudgesEnabled
    @State private var conversationPersistenceEnabled = Config.conversationPersistenceEnabled
    @State private var autoModelRoutingEnabled = Config.autoModelRoutingEnabled
    @State private var smallContextEnabled = Config.llmImageLightweightPromptEnabled

    var body: some View {
        Form {
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
                        Text("\(enabledPersonaCount) active")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    PromptPresetsView(appState: appState)
                } label: {
                    HStack {
                        Label("System Prompt", systemImage: "text.quote")
                        Spacer()
                        Text(Config.savedPresets.first { $0.id == activePresetId }?.name ?? "Default")
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
                InfoToggle(
                    title: "Memory Suggestions",
                    isOn: $memoryNudgesEnabled,
                    info: "After you state a durable fact (\"my daughter's name is Mia\") or repeat a multi-step request, the assistant offers a spoken nudge to remember it or save it as a skill — you confirm by voice. With Agentic Features on, these are saved automatically instead of nudged. Off by default."
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
                    LLMImageSettingsView()
                } label: {
                    HStack {
                        Label("Vision Images", systemImage: "photo.badge.arrow.down")
                        Spacer()
                        Text(Config.llmImagePreset.displayName)
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

            Section {
                Toggle("Small context", isOn: $smallContextEnabled)
                    .onChange(of: smallContextEnabled) { _, value in
                        Config.setLLMImageLightweightPromptEnabled(value)
                    }
            } footer: {
                Text("Off by default. When on, each turn sends a short prompt and recent lines only — no tool list or full system prompt. Use this for tight providers like Groq.")
            }
        }
        .navigationTitle("AI & Personality")
        .ogFormStyle()
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

    private var enabledPersonaCount: Int {
        _ = savedPersonasData
        return Config.enabledPersonas.count
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

        Config.setIntentClassifierEnabled(intentClassifierEnabled)
        Config.setUserMemoryEnabled(userMemoryEnabled)
        Config.setMemoryNudgesEnabled(memoryNudgesEnabled)
        Config.setConversationPersistenceEnabled(conversationPersistenceEnabled)

        appState.restartWakeWordIfDirect()
    }
}

// MARK: - Tools & Actions

/// Tools the AI can use (owner-only; hidden in Simple Mode).
struct ToolsActionsSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
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
                    DeckListView()
                } label: {
                    Label("Study Mode", systemImage: "graduationcap")
                }

                NavigationLink {
                    ReadingStatsView()
                } label: {
                    Label("Reading", systemImage: "book")
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

                NavigationLink {
                    SkillPacksSettingsView()
                        .environmentObject(appState)
                } label: {
                    HStack {
                        Label("Skill Packs", systemImage: "shippingbox")
                        Spacer()
                        if !appState.skillPackStore.installedPacks.isEmpty {
                            Text("\(appState.skillPackStore.installedPacks.count) installed")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink {
                    SiriExposureView()
                } label: {
                    Label("Siri & Search", systemImage: "mic.badge.plus")
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

                NavigationLink {
                    VoiceSkillsManagerView()
                } label: {
                    Label("Voice Skills", systemImage: "waveform")
                }

                if Config.agentModeEnabled {
                    NavigationLink {
                        SuggestedSkillsView()
                    } label: {
                        HStack {
                            Label("Suggested Skills", systemImage: "lightbulb.max")
                            Spacer()
                            let count = EvolvedSkillStore.shared.pending().count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(.red))
                            }
                        }
                    }
                }
            } header: {
                Text("Tools the AI Can Use")
            } footer: {
                Text("Quick Actions are shortcuts you can tap from the widget. Tools are built-in capabilities (camera, search, HomeKit, music…). Custom Tools and Playbooks let you script your own. The Skill Store adds community-built skills.")
            }
        }
        .navigationTitle("Tools & Actions")
        .ogFormStyle()
    }
}

// MARK: - Connections

/// Connected apps & services (owner-only; hidden in Simple Mode).
struct ConnectionsSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServicesSettingsView(appState: appState)
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
                Text("ElevenLabs voices, Perplexity search, broadcast targets, and live-streaming live under Services. Gateways connect the app to external agents — OpenClaw tool bridges and the Hermes agent bridge. MCP Servers expose external tool servers the AI can call.")
            }
        }
        .navigationTitle("Connections")
        .ogFormStyle()
    }
}

// MARK: - Glasses & Privacy

/// Hardware, privacy, and medical compliance (always visible, including Simple Mode).
struct GlassesPrivacySettingsScreen: View {
    @ObservedObject var appState: AppState
    @AppStorage("hipaaMode") private var hipaaMode = false

    // Privacy filter
    @State private var privacyFilterEnabled = Config.privacyFilterEnabled
    @State private var micRoute = Config.micRoute

    // Security
    @State private var conversationEncryptionEnabled = Config.conversationEncryptionEnabled
    @State private var isTogglingEncryption = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HardwarePrivacyView(
                        appState: appState,
                        micRoute: $micRoute,
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
                        if StoreKitService.shared.canAccessMedicalCompliance && hipaaMode {
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
        }
        .navigationTitle("Glasses & Privacy")
        .ogFormStyle()
        .onDisappear {
            saveSettings()
        }
    }

    // MARK: - Save Settings

    private func saveSettings() {
        Config.setPrivacyFilterEnabled(privacyFilterEnabled)
        appState.privacyFilter.isEnabled = privacyFilterEnabled
        Config.setMicRoute(micRoute)

        appState.restartWakeWordIfDirect()
    }
}

// MARK: - Look & Feel

/// Theme, accent colour, and languages (always visible, including Simple Mode).
struct LookFeelSettingsScreen: View {
    @AppStorage("accentColorName") private var accentColorName: String = AppAccent.defaultPresetID
    @AppStorage("appAppearance") private var appearance: String = "dark"

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
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
        }
        .navigationTitle("Look & Feel")
        .ogFormStyle()
    }
}

// MARK: - Advanced

/// Diagnostic / power-user tools (owner-only; hidden in Simple Mode).
struct AdvancedSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    DeveloperPanelView(appState: appState)
                } label: {
                    Label("Developer", systemImage: "stethoscope")
                }

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

                NavigationLink {
                    LiveVisionSettingsView()
                } label: {
                    Label("Live Vision", systemImage: "camera.metering.matrix")
                }

                NavigationLink {
                    DocumentsView()
                } label: {
                    Label("Documents", systemImage: "doc.text.magnifyingglass")
                }

                NavigationLink {
                    CaptureFlowAuthorView()
                } label: {
                    Label("Author Capture-Flow", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Diagnostic tools for power users — inspect the prompts being sent to the AI and watch live network requests. Useful for debugging or building your own integrations.")
            }
        }
        .navigationTitle("Advanced")
        .ogFormStyle()
    }
}

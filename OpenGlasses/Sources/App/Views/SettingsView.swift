import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // Model configs editing
    @State private var modelConfigs: [ModelConfig] = Config.savedModels
    @State private var editingModel: ModelConfig? = nil
    @State private var showAddModel = false

    // Intelligence settings
    @State private var intentClassifierEnabled = Config.intentClassifierEnabled
    @State private var userMemoryEnabled = Config.userMemoryEnabled
    @State private var conversationPersistenceEnabled = Config.conversationPersistenceEnabled

    // Privacy filter
    @State private var privacyFilterEnabled = Config.privacyFilterEnabled
    @State private var useGlassesMicForWakeWord = Config.useGlassesMicForWakeWord

    // Service settings (owned here, bound to ServicesSettingsView)
    @State private var elevenLabsKeyInput = Config.elevenLabsAPIKey
    @State private var selectedVoice = Config.elevenLabsVoiceId
    @State private var emotionAwareTTSEnabled = Config.emotionAwareTTSEnabled
    @State private var perplexityKeyInput = Config.perplexityAPIKey
    @State private var broadcastPlatform = Config.broadcastPlatform
    @State private var broadcastRTMPURL = Config.broadcastRTMPURL
    @State private var broadcastStreamKey = Config.broadcastStreamKey
    @State private var openClawEnabled = Config.openClawEnabled
    @State private var openClawConnectionMode = Config.openClawConnectionMode
    @State private var openClawLanHost = Config.openClawLanHost
    @State private var openClawPort = String(Config.openClawPort)
    @State private var openClawTunnelHost = Config.openClawTunnelHost
    @State private var openClawGatewayToken = Config.openClawGatewayToken
    @State private var openClawTestStatus: String = ""

    var body: some View {
        NavigationStack {
            Form {
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
                } header: {
                    Text("Wake Word")
                } footer: {
                    Text("Choose the phrase that activates the assistant. Personas can override this with their own wake phrases.")
                }

                // MARK: Personas
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
                } header: {
                    Text("Personas")
                } footer: {
                    Text("Each persona has its own wake word, AI model, and personality. Say any persona's wake word to activate it.")
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
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(model.llmProvider.displayName)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if model.visionEnabled {
                                            Image(systemName: "eye")
                                                .font(.caption2)
                                                .foregroundStyle(.tint)
                                        }
                                        if !model.apiKey.isEmpty {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Image(systemName: "exclamationmark.circle")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                    Text("Add API keys for different AI providers. Switch models anytime from the main screen.")
                }

                // MARK: System Prompt
                Section {
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
                    Text("System Prompt")
                } footer: {
                    Text("Choose a prompt preset or create your own to shape how the AI responds.")
                }

                // MARK: Agent Personality
                Section {
                    NavigationLink {
                        AgentPersonalityView(agentDocs: appState.agentDocs)
                    } label: {
                        HStack {
                            Label("Agent Personality", systemImage: "heart.text.clipboard")
                            Spacer()
                            if Config.agentPersonalityEnabled {
                                Text("On")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Give your glasses their own personality with soul.md, skills, and persistent memory. Compatible with OpenClaw agent conventions.")
                }

                // MARK: Intelligence
                Section {
                    Toggle("Intent Classifier", isOn: $intentClassifierEnabled)
                    Toggle("User Memory", isOn: $userMemoryEnabled)
                    Toggle("Conversation History", isOn: $conversationPersistenceEnabled)
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text("Intent classifier ignores nearby conversations so only your voice triggers a response. Memory saves facts you share (your name, preferences) across sessions. History keeps previous conversations for context.")
                }

                // MARK: Hardware
                Section {
                    Toggle("Silent Mode", isOn: Binding(
                        get: { Config.silentMode },
                        set: { newValue in
                            Config.setSilentMode(newValue)
                            if newValue {
                                appState.wakeWordService.stopListening()
                            } else {
                                Task { try? await appState.wakeWordService.startListening() }
                            }
                        }
                    ))
                    Toggle("Listen via Glasses Mic", isOn: $useGlassesMicForWakeWord)
                    Toggle("Blur Bystander Faces", isOn: $privacyFilterEnabled)
                    Toggle("Use Phone Mic for Translation", isOn: Binding(
                        get: { Config.usePhoneMicForTranslation },
                        set: { Config.setUsePhoneMicForTranslation($0) }
                    ))
                } header: {
                    Text("Hardware & Privacy")
                } footer: {
                    Text("Silent Mode turns off the wake word listener — the agent is still actionable via the watch, widget, Action Button, and manual mic tap. Scheduled tasks keep running. Glasses mic enables true hands-free but drains battery faster.")
                }

                // MARK: Transparency
                Section {
                    NavigationLink {
                        ToolsSettingsView(appState: appState)
                    } label: {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                    }

                    NavigationLink {
                        CustomToolsView()
                            .environmentObject(appState)
                    } label: {
                        Label("Custom Tools", systemImage: "hammer")
                    }

                    NavigationLink {
                        QuickActionsSettingsView()
                    } label: {
                        Label("Quick Actions", systemImage: "dial.high")
                    }

                    NavigationLink {
                        ConversationHistoryView()
                            .environmentObject(appState)
                    } label: {
                        HStack {
                            Label("Conversation History", systemImage: "bubble.left.and.bubble.right")
                            Spacer()
                            Text("\(appState.conversationStore.threads.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        PromptInspectorView(appState: appState)
                    } label: {
                        Label("Prompt Inspector", systemImage: "doc.text.magnifyingglass")
                    }

                    NavigationLink {
                        MCPServersView()
                            .environmentObject(appState)
                    } label: {
                        Label("MCP Servers", systemImage: "server.rack")
                    }

                    NavigationLink {
                        NetworkMonitorView()
                    } label: {
                        Label("Network Activity", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Transparency")
                } footer: {
                    Text("See what tools the AI can use, what context is sent, and what network calls are made.")
                }

                // MARK: Services & Integrations
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
                            broadcastStreamKey: $broadcastStreamKey,
                            openClawEnabled: $openClawEnabled,
                            openClawConnectionMode: $openClawConnectionMode,
                            openClawLanHost: $openClawLanHost,
                            openClawPort: $openClawPort,
                            openClawTunnelHost: $openClawTunnelHost,
                            openClawGatewayToken: $openClawGatewayToken,
                            openClawTestStatus: $openClawTestStatus
                        )
                    } label: {
                        Label("Services & Integrations", systemImage: "square.grid.2x2")
                    }
                } footer: {
                    Text("ElevenLabs voice, Perplexity search, live streaming, and OpenClaw gateway.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { saveSettings() }
                }
            }
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
        }
    }

    // MARK: - Save Settings

    private func saveSettings() {
        // Wake word is now managed per-persona in PersonasView
        Config.setSavedModels(modelConfigs)

        if !modelConfigs.contains(where: { $0.id == Config.activeModelId }) {
            if let first = modelConfigs.first {
                Config.setActiveModelId(first.id)
            }
        }
        appState.llmService.refreshActiveModel()

        // System prompt is now managed via PromptPresetsView

        Config.setElevenLabsAPIKey(elevenLabsKeyInput)
        Config.setElevenLabsVoiceId(selectedVoice)

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

        Config.setOpenClawEnabled(openClawEnabled)
        Config.setOpenClawConnectionMode(openClawConnectionMode)
        Config.setOpenClawLanHost(openClawLanHost)
        if let port = Int(openClawPort) {
            Config.setOpenClawPort(port)
        }
        Config.setOpenClawTunnelHost(openClawTunnelHost)
        Config.setOpenClawGatewayToken(openClawGatewayToken)
        appState.openClawBridge.clearCachedEndpoint()

        dismiss()

        if appState.currentMode == .direct {
            Task {
                appState.wakeWordService.stopListening()
                try? await Task.sleep(nanoseconds: 300_000_000)
                try? await appState.wakeWordService.startListening()
            }
        }
    }
}

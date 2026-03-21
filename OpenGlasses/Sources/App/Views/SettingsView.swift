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
                                                .foregroundStyle(.blue)
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
                                    .foregroundStyle(.tertiary)
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

                // MARK: Privacy
                Section {
                    Toggle("Blur Bystander Faces", isOn: $privacyFilterEnabled)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Automatically blurs faces of people nearby in recordings and streams.")
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

import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var wakeWordInput = Config.wakePhrase
    @State private var wakeWordAltsInput = Config.alternativeWakePhrases.joined(separator: ", ")
    @State private var selectedPreset = Config.wakePhrase
    @State private var systemPromptInput = Config.systemPrompt

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

    private let wakeWordPresets = [
        "hey openglasses", "hey claude", "hey jarvis", "hey rayban", "hey computer", "hey assistant"
    ]

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Wake Word
                Section {
                    Picker("Preset", selection: $selectedPreset) {
                        Text("Hey OpenGlasses").tag("hey openglasses")
                        Text("Hey Claude").tag("hey claude")
                        Text("Hey Jarvis").tag("hey jarvis")
                        Text("Hey Rayban").tag("hey rayban")
                        Text("Hey Computer").tag("hey computer")
                        Text("Hey Assistant").tag("hey assistant")
                        if !wakeWordPresets.contains(wakeWordInput.lowercased()) && !wakeWordInput.isEmpty {
                            Text("Custom: \(wakeWordInput)").tag(wakeWordInput.lowercased())
                        }
                    }
                    .onChange(of: selectedPreset) { _, newValue in
                        wakeWordInput = newValue
                        let defaults = Config.defaultAlternativesForPhrase(newValue)
                        wakeWordAltsInput = defaults.joined(separator: ", ")
                    }

                    TextField("Custom wake phrase", text: $wakeWordInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: wakeWordInput) { _, newValue in
                            if !wakeWordPresets.contains(newValue.lowercased()) {
                                selectedPreset = newValue.lowercased()
                            }
                        }

                    if wakeWordInput.split(separator: " ").count < 2 {
                        Label("Use at least 2 words to avoid false triggers", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    TextField("Alternative spellings (comma separated)", text: $wakeWordAltsInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Wake Word")
                } footer: {
                    Text("Add alternate spellings to catch speech-to-text errors, e.g. \"hey cloud\" for \"hey claude.\"")
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
                    TextEditor(text: $systemPromptInput)
                        .frame(minHeight: 150)

                    Button("Reset to Default", role: .destructive) {
                        systemPromptInput = Config.defaultSystemPrompt
                    }
                    .font(.footnote)
                } header: {
                    Text("System Prompt")
                } footer: {
                    Text("This prompt shapes how the AI responds. It's included with every message.")
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
                    }
                }
            }
            .sheet(isPresented: $showAddModel) {
                AddModelView { newModel in
                    modelConfigs.append(newModel)
                }
            }
        }
    }

    // MARK: - Save Settings

    private func saveSettings() {
        Config.setWakePhrase(wakeWordInput)
        let alts = wakeWordAltsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Config.setAlternativeWakePhrases(alts)

        Config.setSavedModels(modelConfigs)

        if !modelConfigs.contains(where: { $0.id == Config.activeModelId }) {
            if let first = modelConfigs.first {
                Config.setActiveModelId(first.id)
            }
        }
        appState.llmService.refreshActiveModel()

        Config.setSystemPrompt(systemPromptInput)

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

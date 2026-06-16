import SwiftUI

/// Settings view for the Agentic Features mode.
/// When enabled, the agent uses soul.md/skills.md/memory.md instead of prompt presets.
struct AgenticFeaturesView: View {
    @ObservedObject var agentDocs: AgentDocumentStore
    @ObservedObject var localLLM: LocalLLMService
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @State private var enabled = Config.agentModeEnabled
    @State private var editingDocument: AgentDocumentStore.DocumentType?
    @State private var tasks: [AgentScheduler.ScheduledTask] = AgentScheduler.savedTasks()
    @State private var showShareSheet = false
    @State private var exportURL: URL?
    @State private var agentModelReady = Config.agentModelDownloaded
    @State private var agentDownloadError: String?
    @State private var selectedAgentModelId = Config.agentModelId
    @State private var downloadedModelIds: [String] = []

    /// Combined picker entries: local downloaded models + configured cloud models.
    private var allAgentModelOptions: [(id: String, label: String)] {
        let local = downloadedModelIds.map { (id: $0, label: "📱 \(modelShortName($0))") }
        let cloud = Config.savedModels
            .filter { $0.llmProvider != .local && $0.llmProvider != .appleOnDevice }
            .map { (id: $0.id, label: "☁️ \($0.name)") }
        return local + cloud
    }

    var body: some View {
        List {
            Section {
                InfoToggle(
                    title: "Agentic Features",
                    isOn: $enabled,
                    info: "Enables autonomous agent capabilities. The assistant can loop, branch, make decisions, and take multi-step actions without waiting for your input each time. Includes background tasks, a notification queue, scheduled actions, and persistent memory. Each persona can be an independent agent with its own soul, skills, and tools. Compatible with OpenClaw and NanoClaw gateways."
                )
                .onChange(of: enabled) { _, on in
                    Config.setAgentModeEnabled(on)
                    if on {
                        appState.agentScheduler.start()
                    } else {
                        appState.agentScheduler.stop()
                    }
                }
            } header: {
                Text("Agentic Mode")
            } footer: {
                Text("Off by default. Turn this on if you want the AI to act on its own — running background tasks, scheduling actions, looping through multi-step plans. Tap \(Image(systemName: "info.circle")) above for the full list of what it unlocks.")
            }

            if enabled {
                // Safety supervisor (Plan S) — deterministic veto rules before any agent action.
                Section {
                    NavigationLink {
                        SafetyRulesView()
                    } label: {
                        Label("Agent Safety", systemImage: "shield.lefthalf.filled")
                    }
                } footer: {
                    Text("Deterministic rules that confirm or block risky actions before they run — voice approval, quiet hours, and an away-from-home geofence.")
                }

                // Agent Model
                Section {
                    // Picker: local downloaded + configured cloud models
                    if allAgentModelOptions.isEmpty {
                        Text("No models available. Download a local model or add a cloud provider below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Active Model", selection: $selectedAgentModelId) {
                            ForEach(allAgentModelOptions, id: \.id) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .onChange(of: selectedAgentModelId) { _, newId in
                            Config.setAgentModelId(newId)
                            agentModelReady = localLLM.isModelDownloaded(newId)
                                || Config.savedModels.contains(where: { $0.id == newId })
                        }
                    }

                    // In-progress download row with cancel
                    if localLLM.isDownloading, let dlId = localLLM.downloadingModelId {
                        HStack {
                            Label(modelShortName(dlId), systemImage: "arrow.down.circle")
                            Spacer()
                            ProgressView(value: localLLM.downloadProgress).frame(width: 60)
                            Text(String(format: "%.0f%%", localLLM.downloadProgress * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 36)
                            Button("Cancel") { localLLM.cancelDownload() }
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    // Download recommended models not yet downloaded
                    ForEach(LocalLLMService.recommendedModels.filter { !downloadedModelIds.contains($0.id) }) { model in
                        if !model.isCompatibleWithDevice {
                            HStack {
                                Label(model.name, systemImage: "memorychip")
                                Spacer()
                                Text("Needs 8 GB RAM")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            .foregroundStyle(.secondary)
                        } else if !localLLM.isDownloading {
                            Button {
                                downloadModel(model.id)
                            } label: {
                                HStack {
                                    Label(model.name, systemImage: "arrow.down.circle")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(model.estimatedSize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Download")
                                        .foregroundStyle(accent)
                                }
                            }
                        }
                    }

                    if let error = agentDownloadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    InfoToggle(
                        title: "Run On-Device Model (experimental)",
                        isOn: Binding(
                            get: { Config.localAgentEnabled },
                            set: { Config.setLocalAgentEnabled($0) }
                        ),
                        info: "Off by default. The bundled on-device (MLX) model is experimental and can crash during inference on some queries. When off, fast queries route to a cloud model instead even if an on-device model is selected. Turn on to use the on-device model for fast, offline tool calls — at the risk of instability."
                    )
                } header: {
                    Text("Agent Model")
                } footer: {
                    Text("Pick a downloaded local model (runs offline) or any configured cloud provider. Cloud handles all tiers reliably; the on-device model is experimental (see the toggle).")
                }

                // Chattiness
                Section {
                    Picker("Chattiness", selection: Binding(
                        get: { Config.agentChattiness },
                        set: { Config.setAgentChattiness($0) }
                    )) {
                        ForEach(Config.AgentChattiness.allCases) { level in
                            Label(level.displayName, systemImage: level.icon).tag(level)
                        }
                    }
                } header: {
                    Text("Behavior")
                } footer: {
                    Text(Config.agentChattiness.description)
                }

                // Check intervals
                Section {
                    Stepper("Connected: every \(Config.agentConnectedInterval) min",
                            value: Binding(
                                get: { Config.agentConnectedInterval },
                                set: { Config.setAgentConnectedInterval($0) }
                            ), in: 1...60)
                    Stepper("Disconnected: every \(Config.agentDisconnectedInterval) min",
                            value: Binding(
                                get: { Config.agentDisconnectedInterval },
                                set: { Config.setAgentDisconnectedInterval($0) }
                            ), in: 5...120)
                } header: {
                    Text("Check Frequency")
                } footer: {
                    Text("How often the agent checks for due tasks. Faster when glasses are on, slower when off to save battery.")
                }
                Section {
                    ForEach(AgentDocumentStore.DocumentType.allCases) { type in
                        Button {
                            editingDocument = type
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: type.icon)
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(type.displayName)
                                            .foregroundStyle(.primary)
                                        Text(type.filename)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    Text(type.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(agentDocs.content(for: type).count) chars")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Meta Agent")
                } footer: {
                    Text("These follow the OpenClaw agent convention. The soul defines who the agent is, skills define what it can do, and memory stores what it learns. The agent can update its own memory but never modify code — that requires a connected OpenClaw.")
                }

                // Shortcut templates
                Section {
                    NavigationLink {
                        ShortcutTemplatesView()
                            .environmentObject(appState)
                    } label: {
                        HStack {
                            Label("Shortcut Templates", systemImage: "square.stack.3d.up")
                            Spacer()
                            Text("\(AgentScheduler.savedTasks().filter { $0.id.hasPrefix("shortcut-") }.count) installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Pre-built templates for email, messages, health, smart home, and more. Preview each before installing.")
                }

                // Scheduled tasks
                Section {
                    NavigationLink {
                        ScheduledTasksView()
                            .environmentObject(appState)
                    } label: {
                        HStack {
                            Label("Scheduled Tasks", systemImage: "clock.arrow.2.circlepath")
                            Spacer()
                            let active = tasks.filter(\.enabled).count
                            Text("\(active)/\(tasks.count) active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Background tasks that run automatically. Search, edit prompts, adjust schedules, and add new tasks.")
                }

                if !Config.agentOnboardingComplete {
                    Section {
                        Button {
                            Config.setAgentOnboardingComplete(true)
                        } label: {
                            Label("Start Onboarding", systemImage: "person.crop.circle.badge.questionmark")
                        }
                    } footer: {
                        Text("The agent will ask you questions to learn about you and customize its personality. Say \"Hey OpenGlasses\" to begin.")
                    }
                }

                Section {
                    Button {
                        exportData()
                    } label: {
                        Label("Export Agent Data", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("Export soul, skills, memory, conversations, and quick actions as a portable zip bundle. Compatible with OpenClaw/nanoclaw agent format.")
                }

                Section {
                    Button(role: .destructive) {
                        resetToDefaults()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                } footer: {
                    Text("Resets soul, skills, and memory to factory defaults. Your learned memories will be lost.")
                }
            }
        }
        .navigationTitle("Agentic Features")
        .onAppear {
            downloadedModelIds = localLLM.downloadedModelIds()
            let isCloud = Config.savedModels.contains(where: { $0.id == Config.agentModelId })
            agentModelReady = isCloud || localLLM.isModelDownloaded(Config.agentModelId)
            if agentModelReady { Config.setAgentModelDownloaded(true) }
            // If saved agent model is no longer available, reset to first available option
            if !agentModelReady, let first = allAgentModelOptions.first {
                Config.setAgentModelId(first.id)
                selectedAgentModelId = first.id
            }
        }
        .sheet(item: $editingDocument) { type in
            AgentDocumentEditorView(type: type, store: agentDocs)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func modelShortName(_ id: String) -> String {
        String(id.split(separator: "/").last ?? Substring(id))
    }

    private func downloadModel(_ modelId: String) {
        agentDownloadError = nil
        Task {
            do {
                try await localLLM.downloadModel(modelId)
                downloadedModelIds = localLLM.downloadedModelIds()
                // Auto-select the newly downloaded model
                selectedAgentModelId = modelId
                Config.setAgentModelId(modelId)
                Config.setAgentModelDownloaded(true)
                agentModelReady = true
            } catch {
                if (error as? CancellationError) == nil {
                    agentDownloadError = error.localizedDescription
                }
            }
        }
    }

    private func resetToDefaults() {
        for type in AgentDocumentStore.DocumentType.allCases {
            agentDocs.save(type, content: type.defaultContent)
        }
        Config.setAgentOnboardingComplete(false)
    }

    private func exportData() {
        do {
            let url = try AgentDataExporter.exportAll(
                agentDocs: agentDocs,
                memoryStore: appState.userMemory,
                conversationStore: appState.conversationStore
            )
            exportURL = url
            showShareSheet = true
        } catch {
            NSLog("[Export] Failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Document Editor

struct AgentDocumentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let type: AgentDocumentStore.DocumentType
    @ObservedObject var store: AgentDocumentStore

    @State private var content = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .navigationTitle(type.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            store.save(type, content: content)
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    content = store.content(for: type)
                }
        }
    }
}

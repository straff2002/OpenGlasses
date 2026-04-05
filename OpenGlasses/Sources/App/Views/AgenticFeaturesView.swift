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
            }

            if enabled {
                // Agent Model
                Section {
                    if agentModelReady {
                        HStack {
                            Label("Gemma 4 E2B", systemImage: "cpu")
                            Spacer()
                            Text("Ready")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    } else if localLLM.isDownloading {
                        HStack {
                            Label("Gemma 4 E2B", systemImage: "cpu")
                            Spacer()
                            ProgressView(value: localLLM.downloadProgress)
                                .frame(width: 80)
                            Text(String(format: "%.0f%%", localLLM.downloadProgress * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 40)
                        }
                    } else {
                        Button {
                            downloadAgentModel()
                        } label: {
                            HStack {
                                Label("Gemma 4 E2B", systemImage: "cpu")
                                Spacer()
                                Text("3.6 GB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Download")
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                    if let error = agentDownloadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Agent Model")
                } footer: {
                    Text("On-device Gemma 4 handles tool calling and fast queries locally — no internet needed. Cloud models are used for complex reasoning.")
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
            // Re-check in case model was downloaded from Local Models view
            agentModelReady = localLLM.isModelDownloaded(Config.agentModelId)
            if agentModelReady { Config.setAgentModelDownloaded(true) }
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

    private func downloadAgentModel() {
        agentDownloadError = nil
        Task {
            do {
                try await localLLM.downloadModel(Config.agentModelId)
                Config.setAgentModelDownloaded(true)
                agentModelReady = true
            } catch {
                agentDownloadError = error.localizedDescription
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

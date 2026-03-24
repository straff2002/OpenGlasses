import SwiftUI

/// Settings view for the Agentic Features mode.
/// When enabled, the agent uses soul.md/skills.md/memory.md instead of prompt presets.
struct AgenticFeaturesView: View {
    @ObservedObject var agentDocs: AgentDocumentStore
    @EnvironmentObject var appState: AppState
    @State private var enabled = Config.agentModeEnabled
    @State private var editingDocument: AgentDocumentStore.DocumentType?
    @State private var tasks: [AgentScheduler.ScheduledTask] = AgentScheduler.savedTasks()
    @State private var showShareSheet = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                Toggle("Agentic Features", isOn: $enabled)
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
                Text("Autonomous agent: background tasks, notification queue, scheduled actions, and persistent memory. Each persona can be an independent agent with its own capabilities.")
            }

            if enabled {
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
                                            .background(.quaternary, in: Capsule())
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
                    Text("Agent Documents")
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
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { task.enabled },
                                set: { newValue in
                                    tasks[index].enabled = newValue
                                    AgentScheduler.saveTasks(tasks)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.name)
                                        .foregroundStyle(.primary)
                                    Text(task.intervalMinutes == 0
                                         ? "Once daily"
                                         : "Every \(task.intervalMinutes) min")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Scheduled Tasks")
                } footer: {
                    Text("Background tasks that run automatically. Morning briefing runs once when you first activate. Others run on their interval when the app is idle.")
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
        .sheet(item: $editingDocument) { type in
            AgentDocumentEditorView(type: type, store: agentDocs)
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(items: [url])
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
                .background(Color(.systemGray6))
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

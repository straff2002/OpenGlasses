import SwiftUI

/// Full-screen management view for scheduled tasks (cron jobs).
/// Designed to handle a growing list — searchable, grouped, with detail navigation.
struct ScheduledTasksView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @State private var tasks: [AgentScheduler.ScheduledTask] = AgentScheduler.savedTasks()
    @State private var searchText = ""
    @State private var showAddTask = false

    private enum TaskGroup: String, CaseIterable {
        case builtIn = "Built-in"
        case shortcuts = "Shortcut Templates"
        case custom = "Custom"
    }

    private var filteredTasks: [AgentScheduler.ScheduledTask] {
        guard !searchText.isEmpty else { return tasks }
        let q = searchText.lowercased()
        return tasks.filter {
            $0.name.lowercased().contains(q) ||
            $0.prompt.lowercased().contains(q) ||
            ($0.createdBy?.lowercased().contains(q) ?? false)
        }
    }

    private func tasksFor(_ group: TaskGroup) -> [AgentScheduler.ScheduledTask] {
        filteredTasks.filter { classify($0) == group }
    }

    private func classify(_ task: AgentScheduler.ScheduledTask) -> TaskGroup {
        let builtInIds = Set(AgentScheduler.ScheduledTask.defaults.map(\.id))
        if builtInIds.contains(task.id) { return .builtIn }
        if task.id.hasPrefix("shortcut-") { return .shortcuts }
        return .custom
    }

    var body: some View {
        List {
            ForEach(TaskGroup.allCases, id: \.self) { group in
                let groupTasks = tasksFor(group)
                if !groupTasks.isEmpty {
                    Section {
                        ForEach(groupTasks) { task in
                            taskRow(task)
                        }
                        .onDelete { offsets in
                            deleteFromGroup(group, offsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text(group.rawValue)
                            Spacer()
                            Text("\(groupTasks.filter(\.enabled).count)/\(groupTasks.count) active")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if filteredTasks.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, prompt: "Search tasks")
        .navigationTitle("Scheduled Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddTask = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddTask) {
            AddTaskSheet { newTask in
                tasks.append(newTask)
                AgentScheduler.saveTasks(tasks)
            }
        }
    }

    // MARK: - Task Row

    private func taskRow(_ task: AgentScheduler.ScheduledTask) -> some View {
        NavigationLink {
            ScheduledTaskDetailView(
                task: task,
                onSave: { updated in
                    if let idx = tasks.firstIndex(where: { $0.id == updated.id }) {
                        tasks[idx] = updated
                        save()
                    }
                },
                onRun: {
                    Task { await runTaskNow(task) }
                }
            )
            .environmentObject(appState)
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: bindEnabled(for: task.id))
                    .labelsHidden()
                    .tint(accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.body)
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Label(scheduleLabel(task), systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let lastRun = task.lastRun {
                            Text(lastRun, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                if task.speakResult {
                    Image(systemName: "speaker.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Helpers

    private func bindEnabled(for id: String) -> Binding<Bool> {
        Binding(
            get: { tasks.first(where: { $0.id == id })?.enabled ?? false },
            set: { newValue in
                if let idx = tasks.firstIndex(where: { $0.id == id }) {
                    tasks[idx].enabled = newValue
                    save()
                }
            }
        )
    }

    private func scheduleLabel(_ task: AgentScheduler.ScheduledTask) -> String {
        if task.intervalMinutes == 0 { return "Once daily" }
        if task.intervalMinutes >= 60 {
            let hours = task.intervalMinutes / 60
            let mins = task.intervalMinutes % 60
            return mins > 0 ? "Every \(hours)h \(mins)m" : "Every \(hours)h"
        }
        return "Every \(task.intervalMinutes)m"
    }

    private func save() {
        AgentScheduler.saveTasks(tasks)
    }

    private func deleteFromGroup(_ group: TaskGroup, offsets: IndexSet) {
        let groupTasks = tasksFor(group)
        let idsToDelete = offsets.map { groupTasks[$0].id }
        tasks.removeAll { idsToDelete.contains($0.id) }
        save()
    }

    private func runTaskNow(_ task: AgentScheduler.ScheduledTask) async {
        guard !appState.isProcessing else { return }
        await appState.sendTextMessage(task.prompt)
    }
}

// MARK: - Task Detail View

/// Full detail screen for a scheduled task — standard iOS form layout.
struct ScheduledTaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent

    let task: AgentScheduler.ScheduledTask
    var onSave: (AgentScheduler.ScheduledTask) -> Void
    var onRun: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var intervalMinutes: Int = 15
    @State private var speakResult: Bool = true
    @State private var hasChanges = false

    var body: some View {
        Form {
            // Info
            Section {
                LabeledContent("Status", value: task.enabled ? "Active" : "Paused")
                if let lastRun = task.lastRun {
                    LabeledContent("Last Run") {
                        Text(lastRun, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
                if let createdBy = task.createdBy, !createdBy.isEmpty {
                    LabeledContent("Created By", value: createdBy)
                }
            }

            // Name
            Section("Name") {
                TextField("Task name", text: $name)
                    .onChange(of: name) { _, _ in hasChanges = true }
            }

            // Prompt
            Section {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .onChange(of: prompt) { _, _ in hasChanges = true }
            } header: {
                HStack {
                    Text("Prompt")
                    Spacer()
                    Text("\(prompt.count) characters")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } footer: {
                Text("The instruction the AI runs on schedule. Write it like you're talking to the assistant.")
            }

            // Schedule
            Section {
                Stepper(
                    intervalMinutes == 0
                        ? "Once daily"
                        : "Every \(intervalMinutes) minutes",
                    value: $intervalMinutes,
                    in: 0...480,
                    step: intervalMinutes < 30 ? 5 : 15
                )
                .onChange(of: intervalMinutes) { _, _ in hasChanges = true }

                if intervalMinutes > 0 {
                    LabeledContent("Runs per day", value: "~\(1440 / max(intervalMinutes, 1))")
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text(intervalMinutes == 0
                     ? "Runs once when the agent starts each day."
                     : "Runs approximately every \(intervalMinutes) minutes when the agent is idle.")
            }

            // Options
            Section {
                Toggle("Speak Result", isOn: $speakResult)
                    .onChange(of: speakResult) { _, _ in hasChanges = true }
            } header: {
                Text("Options")
            } footer: {
                Text("When enabled, the result is spoken via TTS. When off, the task runs silently in the background.")
            }

            // Actions
            Section {
                Button {
                    onRun()
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(appState.isProcessing)
            }
        }
        .navigationTitle(name.isEmpty ? "Task" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if hasChanges {
                    Button("Save") {
                        saveChanges()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            name = task.name
            prompt = task.prompt
            intervalMinutes = task.intervalMinutes
            speakResult = task.speakResult
        }
        .onDisappear {
            if hasChanges {
                saveChanges()
            }
        }
    }

    private func saveChanges() {
        var updated = task
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.prompt = prompt.trimmingCharacters(in: .whitespaces)
        updated.intervalMinutes = intervalMinutes
        updated.speakResult = speakResult
        onSave(updated)
        hasChanges = false
    }
}

// MARK: - Add Task Sheet

private struct AddTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    var onAdd: (AgentScheduler.ScheduledTask) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var intervalMinutes = 30
    @State private var speakResult = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Check train delays", text: $name)
                }
                Section {
                    TextEditor(text: $prompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("The instruction the AI runs on schedule. If there's nothing to report, it stays silent.")
                }
                Section("Schedule") {
                    Stepper(
                        intervalMinutes == 0
                            ? "Once daily"
                            : "Every \(intervalMinutes) min",
                        value: $intervalMinutes,
                        in: 0...480,
                        step: intervalMinutes < 30 ? 5 : 15
                    )
                }
                Section {
                    Toggle("Speak Result", isOn: $speakResult)
                } footer: {
                    Text("Speak the result aloud via TTS, or run silently in the background.")
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let task = AgentScheduler.ScheduledTask(
                            id: "user-\(UUID().uuidString.prefix(8).lowercased())",
                            name: name.isEmpty ? "Untitled Task" : name,
                            prompt: prompt,
                            intervalMinutes: intervalMinutes,
                            enabled: true,
                            speakResult: speakResult,
                            createdBy: "user"
                        )
                        onAdd(task)
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

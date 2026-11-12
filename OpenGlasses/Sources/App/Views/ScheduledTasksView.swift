import SwiftUI

/// Full-screen management view for scheduled tasks (cron jobs).
/// Designed to handle a growing list — searchable, grouped, with detail navigation.
struct ScheduledTasksView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.appAccent) private var accent
    @State private var tasks: [AgentScheduler.ScheduledTask] = AgentScheduler.savedTasks()
    @State private var searchText = ""
    @State private var showAddTask = false
    /// For a goal check-in's row: the goal's title and cadence (Plan IW P2).
    @ObservedObject private var goalStore = GoalStore.shared

    private enum TaskGroup: String, CaseIterable {
        case builtIn = "Built-in"
        case shortcuts = "Shortcut Templates"
        case custom = "Custom"

        var title: LocalizedStringKey {
            switch self {
            case .builtIn: return "Built-in"
            case .shortcuts: return "Shortcut Templates"
            case .custom: return "Custom"
            }
        }
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
        // A goal's check-in is the app's own task, set from the goal — not a custom prompt.
        if task.goalCheckInID != nil { return .builtIn }
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
                            if let goalID = task.goalCheckInID {
                                checkInRow(task, goalID: goalID)
                                    .deleteDisabled(true)
                            } else {
                                taskRow(task)
                            }
                        }
                        .onDelete { offsets in
                            deleteFromGroup(group, offsets: offsets)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
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
        .ogFormStyle()
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
                save()
            }
        }
    }

    // MARK: - Goal check-in row (Plan IW P2)

    /// A goal's check-in, under its goal's title. Not editable here: the cadence is set on the
    /// goal, and the row opens it.
    private func checkInRow(_ task: AgentScheduler.ScheduledTask, goalID: UUID) -> some View {
        let goal = goalStore.goal(id: goalID)
        return NavigationLink {
            GoalPage(goalID: goalID)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: goal?.title ?? task.name)
                    .font(.body)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label {
                        Text(verbatim: [String(localized: "Goal check-in", comment: "Scheduled Tasks: a goal's check-in."),
                                        GoalsScreenModel.cadenceLabel(goal?.checkIn ?? .none),
                                        task.enabled ? nil : String(localized: "paused", comment: "Scheduled Tasks: a paused goal's check-in.")]
                            .compactMap { $0 }.joined(separator: " · "))
                    } icon: {
                        Image(systemName: "target")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let lastRun = task.lastRun {
                        Text(lastRun, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the goal, where its check-ins are set."))
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
                state: appState.agentScheduler.state(for: task.id),
                nextRun: SchedulePolicy.nextRun(task: task, state: appState.agentScheduler.state(for: task.id),
                                                now: Date(), calendar: .current),
                onRun: { await runTaskNow(task) }
            )
            .environmentObject(appState)
        } label: {
            HStack(spacing: 10) {
                // Named so VoiceOver doesn't reach an unnamed switch;
                // `.labelsHidden()` only hides it visually.
                Toggle(task.name, isOn: bindEnabled(for: task.id))
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
        if task.intervalMinutes == 0 { return String(localized: "Once daily") }
        if task.intervalMinutes >= 60 {
            let hours = task.intervalMinutes / 60
            let mins = task.intervalMinutes % 60
            return mins > 0 ? String(localized: "Every \(hours)h \(mins)m") : String(localized: "Every \(hours)h")
        }
        return String(localized: "Every \(task.intervalMinutes)m")
    }

    /// The prompt tasks as edited here, with the check-in tasks as they are stored now — this
    /// screen's copy of those may be out of date (Plan IW P2).
    private func save() {
        AgentScheduler.saveTasks(GoalCheckInSchedule.mergingEdits(tasks, into: AgentScheduler.savedTasks()))
    }

    private func deleteFromGroup(_ group: TaskGroup, offsets: IndexSet) {
        let groupTasks = tasksFor(group)
        let idsToDelete = offsets.map { groupTasks[$0].id }
        tasks.removeAll { idsToDelete.contains($0.id) }
        save()
    }

    /// Plan LM P3: the same run, outcome and record as a scheduled one. Returns the task's state
    /// after it, for the detail screen.
    private func runTaskNow(_ task: AgentScheduler.ScheduledTask) async -> ScheduledTaskState? {
        guard !appState.isProcessing else { return appState.agentScheduler.state(for: task.id) }
        await appState.agentScheduler.runNow(taskID: task.id)
        tasks = AgentScheduler.savedTasks()
        return appState.agentScheduler.state(for: task.id)
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
    /// Plan LM P3: how its runs have gone, and when it can next run.
    @State var state: ScheduledTaskState?
    var nextRun: Date?
    var onRun: () async -> ScheduledTaskState?
    @State private var running = false

    @State private var name: String = ""
    @State private var prompt: String = ""
    @State private var intervalMinutes: Int = 15
    @State private var speakResult: Bool = true
    @State private var hasChanges = false

    var body: some View {
        Form {
            // Info
            Section {
                LabeledContent("Status", value: task.enabled ? String(localized: "Active") : String(localized: "Paused"))
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

            runsSection

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
                     ? "Runs once a day, the first time the assistant checks after midnight."
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
                    running = true
                    Task { @MainActor in
                        state = await onRun()
                        running = false
                    }
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .disabled(appState.isProcessing || running)
            }
        }
        .navigationTitle(name.isEmpty ? "Task" : name)
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
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

    /// Last success, last attempt, when it can next run, the failure streak and its reason, and
    /// the recent runs. Never what a run said.
    @ViewBuilder
    private var runsSection: some View {
        Section {
            if let success = state?.lastSuccessAt {
                LabeledContent("Last Success") {
                    Text(success, style: .relative).foregroundStyle(.secondary)
                }
            }
            if let attempt = state?.lastAttemptAt, attempt != state?.lastSuccessAt {
                LabeledContent("Last Attempt") {
                    Text(attempt, style: .relative).foregroundStyle(.secondary)
                }
            }
            if task.enabled, let nextRun {
                LabeledContent("Next Run") {
                    if nextRun <= Date() {
                        Text("Now").foregroundStyle(.secondary)
                    } else {
                        Text(nextRun, style: .time).foregroundStyle(.secondary)
                    }
                }
            }
            if let state, state.consecutiveFailures > 0, let failure = state.lastFailure {
                LabeledContent("Failures in a Row", value: "\(state.consecutiveFailures)")
                Text(ScheduledRunWording.outcome(failure))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array((state?.recentRuns ?? []).suffix(5).reversed().enumerated()), id: \.offset) { _, run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ScheduledRunWording.outcome(run.status))
                        .font(.footnote)
                    HStack(spacing: 6) {
                        Text(run.at, style: .relative)
                        Text(verbatim: "·")
                        Text(ScheduledRunWording.trigger(run.trigger))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if state?.recentRuns.isEmpty ?? true {
                Text("No runs recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Runs")
        } footer: {
            Text("A run that fails waits a little longer each time before it tries again. After repeated failures you're told once.")
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
            .ogFormStyle()
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

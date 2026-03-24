import Foundation
import UIKit

/// Scheduled background tasks for the agent personality mode.
/// Runs periodic prompts (morning briefing, email check, self-reflection)
/// only when Agent Personality is enabled.
@MainActor
class AgentScheduler: ObservableObject {
    @Published var isRunning = false
    @Published var lastRunTime: Date?

    private var timer: Timer?
    private var morningBriefingDone = false

    weak var appState: AppState?

    /// Built-in scheduled tasks. Users can add more via quick actions.
    struct ScheduledTask: Codable, Identifiable {
        var id: String
        var name: String
        var prompt: String
        var intervalMinutes: Int
        var enabled: Bool
        var lastRun: Date?
        var speakResult: Bool  // Whether to speak the result via TTS

        static let defaults: [ScheduledTask] = [
            ScheduledTask(
                id: "morning-briefing",
                name: "Morning Briefing",
                prompt: "Give me a brief morning update: what's on my calendar today, any reminders due, and the weather. Keep it to 3-4 sentences.",
                intervalMinutes: 0,  // 0 = once per day, on first activation
                enabled: true,
                speakResult: true
            ),
            ScheduledTask(
                id: "periodic-awareness",
                name: "Periodic Check-in",
                prompt: "Based on what you know about me (check my memory), is there anything I should be reminded about right now? Only speak up if there's something relevant. If nothing, just say 'All clear.'",
                intervalMinutes: 30,
                enabled: false,
                speakResult: true
            ),
            ScheduledTask(
                id: "memory-reflection",
                name: "Memory Reflection",
                prompt: "Review what you've learned about me today. Summarize any new facts, patterns, or preferences you've noticed. Update your memory with a concise summary. If nothing new, say so briefly.",
                intervalMinutes: 120,
                enabled: false,
                speakResult: false
            ),
        ]
    }

    // MARK: - Lifecycle

    func start() {
        guard Config.agentPersonalityEnabled else { return }
        guard timer == nil else { return }

        NSLog("[AgentScheduler] Starting")
        morningBriefingDone = false

        // Check every 60 seconds for due tasks
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkScheduledTasks()
            }
        }

        // Run onboarding check immediately if needed
        if !Config.agentOnboardingComplete {
            Task {
                // Small delay so app finishes initializing
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await runOnboarding()
            }
        }

        // Morning briefing on first start of the day
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await checkMorningBriefing()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSLog("[AgentScheduler] Stopped")
    }

    // MARK: - Onboarding

    /// First-time onboarding: the agent asks questions to populate memory.
    private func runOnboarding() async {
        guard let appState, Config.agentPersonalityEnabled else { return }
        guard !Config.agentOnboardingComplete else { return }
        guard !appState.isProcessing, !appState.isListening else { return }

        NSLog("[AgentScheduler] Running onboarding")

        let onboardingPrompt = """
        This is your first interaction with your new wearer. You don't know anything about them yet.

        Introduce yourself warmly (you're an AI that lives on their smart glasses). Then ask them \
        3-4 friendly questions to get to know them:
        - Their name
        - What they mainly want to use the glasses for
        - Any daily routines you should know about

        Keep it conversational and brief — remember this is spoken aloud. After they respond, \
        store what you learn in your memory using [REMEMBER] commands.

        End by saying you'll learn more about them over time.
        """

        await executeAgentPrompt(onboardingPrompt, speakResult: true)
        Config.setAgentOnboardingComplete(true)
    }

    // MARK: - Morning Briefing

    private func checkMorningBriefing() async {
        guard !morningBriefingDone else { return }
        guard let appState, Config.agentPersonalityEnabled else { return }
        guard !appState.isProcessing, !appState.isListening else { return }

        let tasks = loadTasks()
        guard let briefing = tasks.first(where: { $0.id == "morning-briefing" && $0.enabled }) else { return }

        // Check if already run today
        if let lastRun = briefing.lastRun, Calendar.current.isDateInToday(lastRun) {
            morningBriefingDone = true
            return
        }

        NSLog("[AgentScheduler] Running morning briefing")
        morningBriefingDone = true
        await executeAgentPrompt(briefing.prompt, speakResult: briefing.speakResult)
        markTaskRun("morning-briefing")
    }

    // MARK: - Periodic Tasks

    private func checkScheduledTasks() async {
        guard let appState, Config.agentPersonalityEnabled else { return }
        guard !appState.isProcessing, !appState.isListening, !appState.speechService.isSpeaking else { return }

        let tasks = loadTasks()
        let now = Date()

        for task in tasks where task.enabled && task.intervalMinutes > 0 {
            let interval = TimeInterval(task.intervalMinutes * 60)
            if let lastRun = task.lastRun {
                if now.timeIntervalSince(lastRun) < interval { continue }
            }

            NSLog("[AgentScheduler] Running task: %@", task.name)
            await executeAgentPrompt(task.prompt, speakResult: task.speakResult)
            markTaskRun(task.id)

            // Only run one task per cycle to avoid overwhelming
            break
        }
    }

    // MARK: - Execution

    private func executeAgentPrompt(_ prompt: String, speakResult: Bool) async {
        guard let appState else { return }

        isRunning = true
        defer { isRunning = false }

        do {
            let response = try await appState.llmService.sendMessage(
                prompt,
                locationContext: appState.locationService.locationContext,
                memoryContext: Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil,
                agentContext: appState.currentAgentContext
            )

            let processed = Config.userMemoryEnabled
                ? appState.userMemory.parseAndExecuteCommands(in: response)
                : response

            appState.lastResponse = processed

            if speakResult {
                await appState.speechService.speak(processed)
            }

            NSLog("[AgentScheduler] Task complete: %@", String(processed.prefix(100)))
        } catch {
            NSLog("[AgentScheduler] Task failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Persistence

    private func loadTasks() -> [ScheduledTask] {
        if let data = UserDefaults.standard.data(forKey: "agentScheduledTasks"),
           let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            return tasks
        }
        return ScheduledTask.defaults
    }

    private func markTaskRun(_ id: String) {
        var tasks = loadTasks()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].lastRun = Date()
            if let data = try? JSONEncoder().encode(tasks) {
                UserDefaults.standard.set(data, forKey: "agentScheduledTasks")
            }
        }
    }

    static func savedTasks() -> [ScheduledTask] {
        if let data = UserDefaults.standard.data(forKey: "agentScheduledTasks"),
           let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            return tasks
        }
        return ScheduledTask.defaults
    }

    static func saveTasks(_ tasks: [ScheduledTask]) {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: "agentScheduledTasks")
        }
    }
}

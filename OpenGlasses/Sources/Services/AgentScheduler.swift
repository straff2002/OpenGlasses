import Foundation
import UIKit

/// Scheduled background tasks for the agent personality mode.
/// Runs periodic agent prompts (calendar checks, awareness, self-reflection)
/// only when Agentic Features is enabled.
@MainActor
class AgentScheduler: ObservableObject {
    @Published var isRunning = false
    @Published var lastRunTime: Date?

    private var timer: Timer?
    weak var appState: AppState?
    /// The activity trail (Plan IW P1): one entry per run, whether or not its result is spoken —
    /// the run history this scheduler otherwise keeps only as `lastRun`. Wired by AppState.
    var activityRecorder: ActivityRecording?
    /// Plan IW P2: where a goal check-in's digest line is filed. Wired by AppState to the
    /// notification digest (`DigestSource.goal`).
    var fileGoalCheckIn: ((GoalCheckInOutput) -> Void)?
    /// The goals the check-ins read — nil while the store cannot be read, when nothing is
    /// reconciled or run (an unreadable store reads as no goals, which would drop every check-in).
    var goals: () -> [Goal]? = { GoalStore.shared.isUnreadable ? nil : GoalStore.shared.goals }
    var agentModeEnabled: () -> Bool = { Config.agentModeEnabled }

    /// Built-in scheduled tasks. Users can add more via quick actions.
    struct ScheduledTask: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var prompt: String
        var intervalMinutes: Int
        var enabled: Bool
        var lastRun: Date?
        var speakResult: Bool      // Whether to speak the result via TTS
        var personaId: String?     // Which persona/agent runs this (nil = default/current)
        var modelId: String?       // Specific model override (nil = persona's model or active model)
        var createdBy: String?     // Which agent created this task (for audit trail)
        /// Nil for an ordinary prompt task. A goal's check-in (Plan IW P2) is typed instead: it
        /// makes no model call and says only what `GoalPhraser.checkIn(for:)` builds.
        var kind: ScheduledTaskKind? = nil
        /// When this task last said something unprompted — a goal check-in's sentence. What the
        /// daily cap on goal sentences counts.
        var lastSpokenAt: Date? = nil

        static let defaults: [ScheduledTask] = [
            ScheduledTask(
                id: "calendar-check",
                name: "Upcoming Events",
                prompt: "Check the calendar for events in the next 30 minutes. If there's an upcoming meeting or event, remind me with the name, time, and location. If nothing is coming up, there's nothing to report.",
                intervalMinutes: 15,
                enabled: true,
                speakResult: true
            ),
            ScheduledTask(
                id: "periodic-awareness",
                name: "Context Check",
                prompt: "Check my reminders for anything due now or overdue. Check if there are any timer or alarm results pending. If nothing needs attention, there's nothing to report.",
                intervalMinutes: 30,
                enabled: false,
                speakResult: true
            ),
            ScheduledTask(
                id: "memory-reflection",
                name: "Memory Reflection",
                prompt: "Review recent conversations. Extract any new facts, preferences, or patterns worth remembering. Store them in memory using [REMEMBER] commands. This is a background task — no need to speak unless you learned something significant.",
                intervalMinutes: 120,
                enabled: false,
                speakResult: false
            ),
            ScheduledTask(
                id: "capability-review",
                name: "Suggest Improvements",
                prompt: "Use the discover_capabilities tool with category 'all' to see what's available on this device. Then use category 'suggest' to think about useful automations. If you have a genuinely useful suggestion the operator hasn't heard before, propose it briefly. If you've already suggested everything obvious, there's nothing to report.",
                intervalMinutes: 0,  // Once daily
                enabled: false,
                speakResult: true
            ),
        ]
    }

    // MARK: - Lifecycle

    func start() {
        guard Config.agentModeEnabled else { return }
        guard timer == nil else { return }

        PrivacyLog.agent(.scheduler, .started)
        scheduleNextCheck()

        // Run onboarding check immediately if needed
        if !Config.agentOnboardingComplete {
            Task {
                // Small delay so app finishes initializing
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await runOnboarding()
            }
        }

    }

    /// Schedule the next check based on glasses connection state.
    private func scheduleNextCheck() {
        timer?.invalidate()
        let connected = appState?.isConnected ?? false
        let interval = connected
            ? TimeInterval(Config.agentConnectedInterval * 60)
            : TimeInterval(Config.agentDisconnectedInterval * 60)

        PrivacyLog.agent(.scheduler, .checkScheduled,
                         reason: PrivacyToken(connected ? "connected" : "disconnected"),
                         minutes: Int(interval / 60))

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.checkScheduledTasks()
                // Re-schedule with potentially updated interval
                self?.scheduleNextCheck()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        PrivacyLog.agent(.scheduler, .stopped)
    }

    // MARK: - Onboarding

    /// First-time onboarding: the agent asks questions to populate memory.
    private func runOnboarding() async {
        guard let appState, Config.agentModeEnabled else { return }
        guard !Config.agentOnboardingComplete else { return }
        guard !appState.isProcessing, !appState.isListening else { return }

        PrivacyLog.agent(.scheduler, .onboardingRun)

        let onboardingPrompt = """
        This is your first interaction with your new user. You don't know anything about them yet.

        Introduce yourself warmly as their private Avenkin AI assistant, and say plainly that \
        you're an AI. Then ask them \
        3-4 friendly questions to get to know them:
        - Their name
        - What they mainly want your help with
        - Any daily routines you should know about

        Keep it conversational and brief — remember this is spoken aloud. After they respond, \
        store what you learn in your memory using [REMEMBER] commands.

        End by saying you'll learn more about them over time.
        """

        // In the conversation, unlike a scheduled task: the wearer answers its questions next.
        await executeAgentPrompt(onboardingPrompt, speakResult: true, scheduled: false)
        Config.setAgentOnboardingComplete(true)
    }

    // MARK: - Periodic Tasks

    private func checkScheduledTasks() async {
        guard let appState, Config.agentModeEnabled else { return }
        guard !appState.isProcessing, !appState.isListening, !appState.speechService.isSpeaking else { return }

        let now = Date()
        // Goal check-ins first: they make no model call, so a slow prompt task cannot hold one up.
        runGoalCheckIns(now: now, wearerPresent: appState.agentNotificationQueue.canDeliverImmediately)
        let tasks = loadTasks()

        // `isDue` is false for every typed task, so only prompt tasks reach the model here.
        for task in tasks where ScheduleDuePolicy.isDue(task: task, now: now, calendar: .current) {

            // A task's name is the wearer's own instruction to their agent ("check whether the
            // clinic replied"), so which task ran is not written down; the model it was pinned
            // to is a catalog id and is.
            PrivacyLog.agent(.scheduler, .taskStarted,
                             model: task.modelId.map(PrivacyToken.init),
                             minutes: task.intervalMinutes)
            let outcome = await executeTask(task)
            if outcome == .yielded {
                // Stopped for the wearer's own turn: not run, and nothing else runs over that turn.
                break
            }
            if outcome == .deferred {
                // On-device model can't run while backgrounded — don't mark it run;
                // try the next eligible task (a cloud-backed one can still run).
                continue
            }
            markTaskRun(task.id)

            // Only run one task per cycle to avoid overwhelming
            break
        }
    }

    // MARK: - Goal check-ins (Plan IW P2)

    /// The source label a spoken check-in carries through the notification queue.
    static let goalCheckInSource = "Goal check-in"

    /// Bring the check-in tasks in line with the goals, run the ones that are due, file each in the
    /// digest, say at most the day's allowance, and record each on the activity trail.
    ///
    /// Reached only from the scheduler's own cycle, which runs only while Agent Mode is on — the
    /// policy checks it again rather than trusting the caller.
    func runGoalCheckIns(now: Date, wearerPresent: Bool) {
        guard let goals = goals() else { return }
        let stored = loadTasks()
        let current = GoalCheckInSchedule.reconciled(stored, goals: goals, now: now)
        let result = GoalCheckInPolicy.run(tasks: current, goals: goals,
                                           agentModeEnabled: agentModeEnabled(),
                                           wearerPresent: wearerPresent, now: now, calendar: .current)
        for output in result.outputs {
            fileGoalCheckIn?(output)
            if let line = output.spokenLine {
                appState?.agentNotificationQueue.enqueue(message: line, source: Self.goalCheckInSource,
                                                         priority: .low)
            }
            activityRecorder?.record(ActivityFeed.goalCheckIn(goalID: output.goalID,
                                                              spoken: output.spokenLine != nil, at: now))
        }
        if result.tasks != stored { Self.saveTasks(result.tasks) }
        if !result.outputs.isEmpty {
            let spoke = result.outputs.contains { $0.spokenLine != nil }
            PrivacyLog.agent(.scheduler, .goalCheckInsRan,
                             reason: PrivacyToken(spoke ? "spoke" : "digestOnly"),
                             count: result.outputs.count)
        }
    }

    /// Keep the stored check-in tasks in line with `goals` — called whenever the goals change, so
    /// a goal that is finished, set aside or has its check-ins turned off loses its task at once,
    /// and one given a cadence gains one. Writes only when something changed.
    static func reconcileGoalCheckIns(goals: [Goal], now: Date = Date()) {
        let stored = savedTasks()
        let reconciled = GoalCheckInSchedule.reconciled(stored, goals: goals, now: now)
        if reconciled != stored { saveTasks(reconciled) }
    }

    // MARK: - Execution

    /// Outcome of a scheduled run. `.deferred` means it didn't run and should be
    /// retried later (e.g. an on-device model can't run while backgrounded) — the
    /// caller must NOT mark it as run. `.yielded` means it was stopped for the wearer's own turn:
    /// not run either, and the cycle ends.
    private enum TaskRunOutcome { case completed, deferred, yielded }

    /// What one prompt run came to: whether it counts as run, and — when it did run — what the
    /// trail records about it.
    private struct PromptRun {
        let outcome: TaskRunOutcome
        let result: ScheduledRunResult?

        static let deferred = PromptRun(outcome: .deferred, result: nil)
        static let yielded = PromptRun(outcome: .yielded, result: nil)
        static let notRun = PromptRun(outcome: .completed, result: nil)
    }

    /// One trail entry for one run (Plan IW P1). Deliberately independent of `speakResult`: a
    /// result nobody heard is exactly the one the trail has to show.
    static func recordRun(of task: ScheduledTask, result: ScheduledRunResult,
                          recorder: ActivityRecording?, at now: Date) {
        recorder?.record(ActivityFeed.scheduledRun(taskName: task.name, result: result, at: now))
    }

    /// Execute a scheduled task, switching to its designated model/persona if specified.
    @discardableResult
    private func executeTask(_ task: ScheduledTask) async -> TaskRunOutcome {
        guard let appState else { return .completed }

        // Save current model so we can restore after
        let previousModelId = Config.activeModelId
        var personaName: String?

        // Switch to the task's persona/model if specified
        if let personaId = task.personaId,
           let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
            Config.setActiveModelId(persona.modelId)
            Config.setActivePresetId(persona.presetId)
            appState.llmService.refreshActiveModel()
            personaName = persona.name
            // Persona names are omitted rather than fingerprinted: the set is small and
            // wearer-visible, so a stable hash would not anonymise which persona was in use.
            PrivacyLog.agent(.scheduler, .personaSwitched, model: PrivacyToken(persona.modelId))
        } else if let modelId = task.modelId {
            Config.setActiveModelId(modelId)
            appState.llmService.refreshActiveModel()
            PrivacyLog.agent(.scheduler, .modelSwitched, model: PrivacyToken(modelId))
        }

        // Run the task. Inside the run, the router knows its tool calls are the scheduled task's.
        let run = await ActivityScope.$scheduledTask.withValue(task.name) {
            await executeAgentPrompt(task.prompt, speakResult: task.speakResult, scheduled: true,
                                     personaId: task.personaId, personaName: personaName)
        }
        let outcome = run.outcome
        if let result = run.result {
            Self.recordRun(of: task, result: result, recorder: activityRecorder, at: Date())
        }

        // Restore previous model
        if task.personaId != nil || task.modelId != nil {
            Config.setActiveModelId(previousModelId)
            appState.llmService.refreshActiveModel()
            PrivacyLog.agent(.scheduler, .modelRestored, model: PrivacyToken(previousModelId))
        }

        return outcome
    }

    @discardableResult
    private func executeAgentPrompt(_ prompt: String, speakResult: Bool, scheduled: Bool,
                                    personaId: String? = nil, personaName: String? = nil) async -> PromptRun {
        guard let appState else { return .notRun }

        // Don't let a scheduled task auto-load the on-device model. Loading the (multi-GB)
        // MLX model is slow and, on launch, makes startup drag (and has crashed). If the
        // active model is on-device and not already in memory, defer — the user loads it
        // on demand via the home-screen "Load" control, after which scheduled tasks run.
        if let local = appState.llmService.localLLMService,
           let active = Config.activeModel, active.llmProvider == .local,
           !(local.isModelLoaded && local.loadedModelId == active.model) {
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("modelNotLoaded"))
            return .deferred
        }

        isRunning = true
        defer { isRunning = false }

        // Wrap a scheduled task's prompt so the agent knows to stay quiet when nothing to report.
        // Onboarding always speaks.
        let wrappedPrompt = scheduled ? """
        \(prompt)

        IMPORTANT: If there is nothing noteworthy to report, respond with exactly "[NOTHING]" \
        and nothing else. Only speak up if there is something the user would actually want to know. \
        Do not report routine/expected states. Be decisive — either report something useful or say [NOTHING].
        """ : prompt

        do {
            // Plan CU P1: a scheduled run fires on its own timer and can overlap a voice turn,
            // through the very `sendMessage` / `runToolLoop` that turn is using. Off-turn, so it
            // cannot re-tag that turn's cohort with this run's model or add its tool seconds to it —
            // see `TurnRecorder.offTurn`.
            let response = try await TurnRecorder.offTurn {
                let llm = appState.llmService
                let location = appState.locationService.locationContext
                let memory = appState.memoryContextForPrompt()
                let agent = appState.currentAgentContext
                // A scheduled task reads the conversation and leaves nothing in it; a voice turn
                // that starts meanwhile stops it (`sendOffConversation`).
                return scheduled
                    ? try await llm.sendOffConversation(wrappedPrompt, locationContext: location,
                                                        memoryContext: memory, agentContext: agent)
                    : try await llm.sendMessage(wrappedPrompt, locationContext: location,
                                                memoryContext: memory, agentContext: agent)
            }

            let processed = Config.userMemoryEnabled
                ? appState.userMemory.parseAndExecuteCommands(in: response)
                : response

            // Check if the agent decided there's nothing to report
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[NOTHING]" || trimmed.lowercased().contains("[nothing]") {
                PrivacyLog.agent(.scheduler, .taskProducedNothing)
                return PromptRun(outcome: .completed, result: .nothingToReport)
            }

            appState.lastResponse = processed

            if speakResult {
                appState.agentNotificationQueue.enqueue(
                    message: processed,
                    source: "Agent Task",
                    priority: .medium,
                    personaId: personaId,
                    personaName: personaName
                )
            }

            // The response is what the agent found out about the wearer's day — the single most
            // content-bearing string this file holds — so only its length survives.
            PrivacyLog.agent(.scheduler, .taskCompleted, characters: processed.count)
            return PromptRun(outcome: .completed, result: .reported(processed))
        } catch is LLMService.OffConversationRunYielded {
            // The wearer started a turn: not run, so it is tried again next cycle.
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("yieldedToTurn"))
            return .yielded
        } catch LocalLLMError.backgrounded {
            // On-device model can't run while backgrounded — defer, don't consume the run.
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("backgrounded"))
            return .deferred
        } catch {
            PrivacyLog.agent(.scheduler, .taskFailed, error: SafeErrorSummary(error))
            return PromptRun(outcome: .completed, result: .failed)
        }
    }

    // MARK: - Persistence

    private func loadTasks() -> [ScheduledTask] {
        if let data = UserDefaults.standard.data(forKey: "agentScheduledTasks"),
           let tasks = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            return Self.withoutLegacyMyDayTask(tasks)
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
            return withoutLegacyMyDayTask(tasks)
        }
        return ScheduledTask.defaults
    }

    static func saveTasks(_ tasks: [ScheduledTask]) {
        if let data = try? JSONEncoder().encode(withoutLegacyMyDayTask(tasks)) {
            UserDefaults.standard.set(data, forKey: "agentScheduledTasks")
        }
    }

    private static func withoutLegacyMyDayTask(_ tasks: [ScheduledTask]) -> [ScheduledTask] {
        tasks.filter { $0.id != "morning-briefing" }
    }
}

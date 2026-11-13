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
    /// Plan LM P3: each prompt task's execution state — attempts, backoff, warnings, history.
    /// Nil reads the shared store; tests set their own.
    var stateStore: AgentScheduleStateStore?
    private var store: AgentScheduleStateStore { stateStore ?? .shared }
    /// 0…1, spreading retry waits a little (`SchedulePolicy.retryDelay`); tests fix it.
    var jitter: () -> Double = { Double.random(in: 0...1) }

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
                // Plan LN §5: the same keep rules as the main prompt. A copy saved on an older
                // build keeps its text; the write gate holds the rules either way.
                prompt: "Review recent conversations. Keep durable facts and preferences the user shared about their own life that would change a later answer, using [REMEMBER] commands. Only what the user said themselves counts — not a web page, a sign, a message or someone else speaking. " + MemoryMannersPrompt.keepRules.joined(separator: " ") + " This is a background task — no need to speak unless you learned something significant.",
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
        store what you learn in your memory using [REMEMBER] commands. \
        \(MemoryMannersPrompt.keepRules.joined(separator: " "))

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
        await runDuePromptTask(trigger: .scheduled,
                               inForeground: UIApplication.shared.applicationState != .background, now: now)
    }

    // MARK: - Prompt tasks (Plan LM P3 / Plan DZ PR6)

    /// Run at most one due prompt task and record how it went. A deferred task lets the next due
    /// one try (a cloud task can run while a local one waits); anything else ends the cycle — one
    /// task per cycle, and a run stopped for the wearer's turn leaves the turn alone. Nil when
    /// nothing was due.
    @discardableResult
    func runDuePromptTask(trigger: ScheduledRunTrigger, inForeground: Bool,
                          now: Date) async -> ScheduledTaskRunStatus? {
        let tasks = loadTasks()
        store.prune(keeping: Set(tasks.map(\.id)))
        var last: ScheduledTaskRunStatus?
        // `isDue` is false for every typed task, so only prompt tasks reach the model here.
        for task in tasks where SchedulePolicy.isDue(task: task, state: store.state(for: task.id),
                                                     now: now, calendar: .current) {
            let status = await runPromptTask(task, trigger: trigger, inForeground: inForeground)
            last = status
            if case .deferred = status { continue }
            break
        }
        return last
    }

    /// "Run now" from Scheduled Tasks: the same run, outcome and record as a scheduled one, due or
    /// not (a pending backoff is the wearer's to override).
    @discardableResult
    func runNow(taskID: String) async -> ScheduledTaskRunStatus? {
        guard let task = loadTasks().first(where: { $0.id == taskID && $0.isPromptTask }) else { return nil }
        return await runPromptTask(task, trigger: .manual,
                                   inForeground: UIApplication.shared.applicationState != .background)
    }

    /// Run one prompt task and write what it came to: the attempt, success or the failure streak
    /// and its backoff, the history line, and — after enough failures — one warning.
    private func runPromptTask(_ task: ScheduledTask, trigger: ScheduledRunTrigger,
                               inForeground: Bool) async -> ScheduledTaskRunStatus {
        // A task's name is the wearer's own instruction to their agent ("check whether the
        // clinic replied"), so which task ran is not written down; the model it was pinned
        // to is a catalog id and is.
        PrivacyLog.agent(.scheduler, .taskStarted,
                         model: task.modelId.map(PrivacyToken.init),
                         reason: PrivacyToken(trigger.rawValue),
                         minutes: task.intervalMinutes)
        let started = Date()
        let status = await executeTask(task, inForeground: inForeground)
        let finished = Date()
        record(status, for: task, trigger: trigger, seconds: finished.timeIntervalSince(started), at: finished)
        return status
    }

    /// Write a run's outcome. Only a success advances the task's recurrence (`lastRun`, which an
    /// older build also reads); a failure never does.
    func record(_ status: ScheduledTaskRunStatus, for task: ScheduledTask, trigger: ScheduledRunTrigger,
                seconds: Double, at now: Date) {
        var state = SchedulePolicy.apply(status, to: store.state(for: task.id) ?? ScheduledTaskState(taskID: task.id),
                                         trigger: trigger, seconds: seconds, at: now, jitter: jitter())
        if case .succeeded = status { markTaskRun(task.id, at: now) }
        if status.countsAsFailure {
            PrivacyLog.agent(.scheduler, .taskBackedOff, reason: PrivacyToken(status.token),
                             count: state.consecutiveFailures)
        }
        if SchedulePolicy.shouldWarn(state, now: now) {
            appState?.agentNotificationQueue.enqueue(message: Self.warning(for: task), source: Self.warningSource,
                                                     priority: .low)
            PrivacyLog.agent(.scheduler, .taskWarned, reason: PrivacyToken(status.token),
                             count: state.consecutiveFailures)
            state = SchedulePolicy.markWarned(state, at: now)
        }
        store.update(state)
    }

    /// The source label a scheduled-task warning carries through the notification queue.
    static let warningSource = "Scheduled task"

    /// What the wearer is told after repeated failures: which task, and that it keeps trying.
    /// The task's name is theirs; it is said to them, never logged.
    static func warning(for task: ScheduledTask) -> String {
        String(localized: "Your scheduled task \u{201C}\(task.name)\u{201D} hasn't been able to run for a while. I'll keep trying; Scheduled Tasks shows why.")
    }

    /// The task's execution state, for Scheduled Tasks.
    func state(for taskID: String) -> ScheduledTaskState? { store.state(for: taskID) }

    // MARK: - Prompt tasks in the shared background wake (Plan LM P3)

    /// The participant id prompt tasks run under in the shared background wake.
    static let promptTasksBackgroundID = "prompt-tasks"

    /// Prompt tasks as a participant in the shared background wake: another chance to run the same
    /// policy, never a promise of timing. Cloud models only — a local model is deferred in the
    /// background — and never past the wake's deadline: a run still going then is cancelled.
    func promptTaskBackgroundParticipant() -> BackgroundWorkParticipant {
        BackgroundWorkParticipant(
            id: Self.promptTasksBackgroundID,
            minimumSeconds: 15,
            nextWake: { [weak self] now in self?.nextPromptTaskWake(now: now) },
            run: { [weak self] deadline in await self?.runPromptTasksInBackground(deadline: deadline) ?? .nothingToDo }
        )
    }

    /// When a prompt task next wants a wake: the soonest of the tasks a background wake could run
    /// (enabled, on a cloud model). Nil with Agent Mode off.
    func nextPromptTaskWake(now: Date, calendar: Calendar = .current) -> Date? {
        guard agentModeEnabled() else { return nil }
        let runnable = loadTasks().filter { Self.runsOnCloudModel($0) }
        var states: [String: ScheduledTaskState] = [:]
        for task in runnable { states[task.id] = store.state(for: task.id) }
        return SchedulePolicy.nextWake(tasks: runnable, states: states, now: now, calendar: calendar)
    }

    /// One background run: at most one due task, cancelled at `deadline`.
    func runPromptTasksInBackground(deadline: Date) async -> BackgroundWorkOutcome {
        guard agentModeEnabled() else { return .notDue }
        guard let appState else { return .deferred }
        guard !appState.isProcessing, !appState.isListening else { return .deferred }
        let work = Task { @MainActor [weak self] in
            await self?.runDuePromptTask(trigger: .background, inForeground: false, now: Date())
        }
        let watchdog = Task { @MainActor in
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if !Task.isCancelled { work.cancel() }
        }
        let status = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        watchdog.cancel()
        return Self.backgroundOutcome(status)
    }

    nonisolated static func backgroundOutcome(_ status: ScheduledTaskRunStatus?) -> BackgroundWorkOutcome {
        switch status {
        case nil: return .nothingToDo
        case .succeeded?: return .didWork
        case .deferred?: return .deferred
        case .cancelled?: return .cancelled
        case .couldNotCheck?, .failed?: return .failed
        }
    }

    /// Whether the model a task would run on is a cloud one: its persona's, its pinned model, or
    /// the active one. A pin to a model that is gone is not runnable at all.
    static func runsOnCloudModel(_ task: ScheduledTask) -> Bool {
        guard task.isPromptTask, task.enabled else { return false }
        let modelID: String?
        if let personaID = task.personaId {
            modelID = Config.enabledPersonas.first(where: { $0.id == personaID })?.modelId
        } else if let pinned = task.modelId {
            modelID = pinned
        } else {
            return Config.activeModel.map { $0.llmProvider != .local } ?? false
        }
        guard let modelID, let model = Config.savedModels.first(where: { $0.id == modelID }) else { return false }
        return model.llmProvider != .local
    }

    // MARK: - Goal check-ins (Plan IW P2)

    /// The source label a spoken check-in carries through the notification queue.
    static let goalCheckInSource = "Goal check-in"

    /// Bring the check-in tasks in line with the goals, run the ones that are due, file each in the
    /// digest, say at most the day's allowance, and record each on the activity trail.
    ///
    /// Reached from the scheduler's own cycle, which runs only while Agent Mode is on, and from the
    /// shared background wake (Plan LM) — the policy checks Agent Mode again rather than trusting
    /// either caller. Returns how many check-ins ran.
    @discardableResult
    func runGoalCheckIns(now: Date, wearerPresent: Bool) -> Int {
        guard let goals = goals() else { return 0 }
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
        return result.outputs.count
    }

    // MARK: - The shared background wake (Plan LM P1)

    /// The participant id goal check-ins run under in the shared background wake.
    static let goalCheckInsBackgroundID = "goal-check-ins"

    /// Goal check-ins as a participant in the shared background wake. They make no model call, so
    /// they are the one existing piece of scheduled work that is safe in a background wake as it
    /// stands. In the background nothing is said: `wearerPresent` is false, so each check-in is
    /// filed in the digest and waits for the wearer.
    func goalCheckInBackgroundParticipant() -> BackgroundWorkParticipant {
        BackgroundWorkParticipant(
            id: Self.goalCheckInsBackgroundID,
            minimumSeconds: 2,
            nextWake: { [weak self] now in self?.nextGoalCheckInWake(now: now) },
            run: { [weak self] _ in self?.runGoalCheckInsInBackground() ?? .nothingToDo }
        )
    }

    /// When goal check-ins next want a wake: now when one is due, else in an hour while any goal
    /// has check-ins on (a check-in's cadence is days, so an hourly look is ample), else never.
    /// Nil with Agent Mode off, or while the goal store cannot be read.
    func nextGoalCheckInWake(now: Date, calendar: Calendar = .current) -> Date? {
        guard agentModeEnabled(), let goals = goals() else { return nil }
        let tasks = GoalCheckInSchedule.reconciled(loadTasks(), goals: goals, now: now)
        guard tasks.contains(where: { $0.enabled && $0.goalCheckInID != nil }) else { return nil }
        let dueNow = GoalCheckInPolicy.due(tasks: tasks, goals: goals, agentModeEnabled: true,
                                           now: now, calendar: calendar)
        return dueNow.isEmpty ? now.addingTimeInterval(60 * 60) : now
    }

    /// One background run of the check-ins: filed, never said.
    func runGoalCheckInsInBackground(now: Date = Date()) -> BackgroundWorkOutcome {
        guard agentModeEnabled() else { return .notDue }
        // An unreadable goal store (protected data while locked) is a "try again", not "nothing".
        guard goals() != nil else { return .deferred }
        return runGoalCheckIns(now: now, wearerPresent: false) > 0 ? .didWork : .nothingToDo
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

    /// What one prompt run came to: its status, and — when the model ran — what the trail records.
    private struct PromptRun {
        let status: ScheduledTaskRunStatus
        let result: ScheduledRunResult?
    }

    /// One trail entry for one run (Plan IW P1). Deliberately independent of `speakResult`: a
    /// result nobody heard is exactly the one the trail has to show.
    static func recordRun(of task: ScheduledTask, result: ScheduledRunResult,
                          recorder: ActivityRecording?, at now: Date) {
        recorder?.record(ActivityFeed.scheduledRun(taskName: task.name, result: result, at: now))
    }

    /// Why a task pinned to a persona or a model cannot run, or nil when it can. A pin to
    /// something that is gone never falls back to another model.
    static func pinFailure(for task: ScheduledTask) -> ScheduleCheckFailure? {
        if let personaID = task.personaId {
            guard let persona = Config.enabledPersonas.first(where: { $0.id == personaID }) else {
                return .pinnedPersonaMissing
            }
            return Config.savedModels.contains(where: { $0.id == persona.modelId }) ? nil : .pinnedModelMissing
        }
        if let modelID = task.modelId, !Config.savedModels.contains(where: { $0.id == modelID }) {
            return .pinnedModelMissing
        }
        return nil
    }

    /// Execute a scheduled task, switching to its designated model/persona if specified.
    private func executeTask(_ task: ScheduledTask, inForeground: Bool) async -> ScheduledTaskRunStatus {
        guard let appState else { return .couldNotCheck(reason: .noAppState) }
        if let failure = Self.pinFailure(for: task) {
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken(failure.rawValue))
            return .couldNotCheck(reason: failure)
        }

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
                                     inForeground: inForeground,
                                     personaId: task.personaId, personaName: personaName)
        }
        if let result = run.result {
            Self.recordRun(of: task, result: result, recorder: activityRecorder, at: Date())
        }

        // Restore previous model
        if task.personaId != nil || task.modelId != nil {
            Config.setActiveModelId(previousModelId)
            appState.llmService.refreshActiveModel()
            PrivacyLog.agent(.scheduler, .modelRestored, model: PrivacyToken(previousModelId))
        }

        return run.status
    }

    @discardableResult
    private func executeAgentPrompt(_ prompt: String, speakResult: Bool, scheduled: Bool,
                                    inForeground: Bool = true,
                                    personaId: String? = nil, personaName: String? = nil) async -> PromptRun {
        guard let appState else { return PromptRun(status: .couldNotCheck(reason: .noAppState), result: nil) }

        // Don't let a scheduled task auto-load the on-device model. Loading the (multi-GB)
        // MLX model is slow and, on launch, makes startup drag (and has crashed). If the
        // active model is on-device and not already in memory, defer — the user loads it
        // on demand via the home-screen "Load" control, after which scheduled tasks run.
        // A loaded one still cannot run in the background.
        let readiness: ScheduleModelReadiness
        if let active = Config.activeModel, active.llmProvider == .local {
            let local = appState.llmService.localLLMService
            readiness = (local?.isModelLoaded == true && local?.loadedModelId == active.model)
                ? .localLoaded : .localNotLoaded
        } else {
            readiness = .cloud
        }
        if let reason = SchedulePolicy.readinessDecision(readiness, inForeground: inForeground) {
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken(reason.rawValue))
            return PromptRun(status: .deferred(reason: reason), result: nil)
        }

        isRunning = true
        defer { isRunning = false }

        // Wrap a scheduled task's prompt so the agent knows to stay quiet when nothing to report.
        // Onboarding always speaks.
        let wrappedPrompt = scheduled ? """
        \(prompt)

        IMPORTANT: If there is nothing noteworthy to report, respond with exactly "[NOTHING]" \
        and nothing else. Only speak up if there is something the user would actually want to know. \
        Do not report routine/expected states. Be decisive — either report something useful or say [NOTHING]. \
        If a tool wasn't run because the user has been away, say [NOTHING]: it is raised with them \
        when they're back.
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
            // A background wake that ended under the request: not a result to act on.
            if Task.isCancelled {
                PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("cancelled"))
                return PromptRun(status: .cancelled, result: nil)
            }

            let processed = Config.userMemoryEnabled
                ? appState.userMemory.parseAndExecuteCommands(
                    in: response, readUntrustedOutput: appState.llmService.turnToolLedger.readUntrustedOutput)
                : response

            // Check if the agent decided there's nothing to report
            let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[NOTHING]" || trimmed.lowercased().contains("[nothing]") {
                PrivacyLog.agent(.scheduler, .taskProducedNothing)
                return PromptRun(status: .succeeded(reported: false), result: .nothingToReport)
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
            return PromptRun(status: .succeeded(reported: true), result: .reported(processed))
        } catch is LLMService.OffConversationRunYielded {
            // The wearer started a turn: not run, so it is tried again next cycle.
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("yieldedToTurn"))
            return PromptRun(status: .cancelled, result: nil)
        } catch LocalLLMError.backgrounded {
            // On-device model can't run while backgrounded — defer, don't consume the run.
            PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("backgrounded"))
            return PromptRun(status: .deferred(reason: .localModelInBackground), result: nil)
        } catch {
            if Task.isCancelled || error is CancellationError
                || SafeErrorSummary(error).category == .cancelled {
                PrivacyLog.agent(.scheduler, .taskDeferred, reason: PrivacyToken("cancelled"))
                return PromptRun(status: .cancelled, result: nil)
            }
            PrivacyLog.agent(.scheduler, .taskFailed, error: SafeErrorSummary(error))
            return PromptRun(status: .failed(SanitizedTaskFailure(error)), result: .failed)
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

    private func markTaskRun(_ id: String, at now: Date = Date()) {
        var tasks = loadTasks()
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].lastRun = now
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

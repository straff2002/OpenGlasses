import Foundation
import Combine

/// Drives a remote agent run (Plan N): dispatches to the active `AgentHarness`, aggregates its
/// normalized event stream into an `AgentRunResult`, narrates key moments and the final summary via
/// TTS, and gates `awaitingInput` confirmations. Harness-agnostic — it works entirely in
/// `AgentEvent`/`AgentRunResult`, so swapping harnesses changes nothing here.
///
/// `speak` is injected (AppState wires TTS; tests capture), and the event-handling state machine is
/// exposed as `handle(_:)` so transitions are unit-testable without a live stream.
@MainActor
final class AgentSessionService: ObservableObject {
    static let shared = AgentSessionService()

    @Published private(set) var activeRun: AgentRun?
    @Published private(set) var result = AgentRunResult()
    @Published private(set) var lastSummary: String?
    @Published private(set) var awaitingInputPrompt: String?
    /// Everything spoken this session, in order — for the debug panel and tests.
    @Published private(set) var spokenLog: [String] = []

    /// A directly-set harness (tests/back-compat). When a `registry` is present it takes precedence,
    /// so a default-harness change in Settings applies without re-dispatching.
    private(set) var harness: AgentHarness?

    /// The harness registry (Phase 2). When set, `dispatch` uses its `active` harness.
    private(set) var registry: AgentHarnessRegistry?

    /// Injected speaker. AppState wires `TextToSpeechService`; tests capture the lines.
    var speak: (String) -> Void = { _ in }

    private var eventTask: Task<Void, Never>?

    init() {}

    // MARK: - Configuration

    func configure(harness: AgentHarness, speak: @escaping (String) -> Void) {
        self.harness = harness
        self.speak = speak
    }

    /// Configure with a registry (Phase 2): the active harness is resolved per dispatch from the
    /// user's default, so adding/removing a Custom endpoint or switching the default takes effect live.
    func configure(registry: AgentHarnessRegistry, speak: @escaping (String) -> Void) {
        self.registry = registry
        self.speak = speak
    }

    func setHarness(_ harness: AgentHarness) { self.harness = harness }

    /// Swap the registry (e.g. after the user edits the Custom endpoint in Settings).
    func setRegistry(_ registry: AgentHarnessRegistry) { self.registry = registry }

    /// The harness a dispatch would use right now (registry default wins).
    var activeHarness: AgentHarness? { registry?.active ?? harness }

    // MARK: - Dispatch

    @discardableResult
    func dispatch(prompt: String, project: String?) async -> Result<AgentRun, AgentHarnessError> {
        guard let harness = activeHarness else { return .failure(.notConfigured(Config.defaultAgentHarness)) }
        guard harness.isConfigured else { return .failure(.notConfigured(harness.kind)) }

        do {
            var run = try await harness.start(prompt: prompt, project: project)
            if run.status == .queued { run.status = .running }
            activeRun = run
            result = AgentRunResult()
            awaitingInputPrompt = nil
            lastSummary = nil
            subscribe(to: run, on: harness)
            return .success(run)
        } catch let error as AgentHarnessError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private func subscribe(to run: AgentRun, on harness: AgentHarness) {
        eventTask?.cancel()
        let stream = harness.events(for: run)
        eventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - State machine (unit-tested directly)

    /// Fold one event into state: update the result tally, narrate if worthwhile, and advance the
    /// run's status (terminal events speak the final summary).
    func handle(_ event: AgentEvent) {
        result.apply(event)
        if let line = AgentSummarizer.narration(for: event) {
            emit(line)
        }
        switch event {
        case .started(let run):
            // Establish (or refresh) the active run — authoritative start from the adapter. In the
            // normal flow `dispatch` already set it; this keeps the state machine self-contained.
            activeRun = run
        case .awaitingInput(let prompt):
            awaitingInputPrompt = prompt
            activeRun?.status = .awaitingInput
        case .completed:
            finish(status: .completed)
        case .error:
            finish(status: .failed)
        case .progress, .fileCreated, .fileModified, .commandRun, .prOpened, .pushed, .assistantText:
            break
        }
    }

    private func finish(status: AgentRunStatus) {
        activeRun?.status = status
        let summary = AgentSummarizer.summarize(result, status: status)
        lastSummary = summary
        emit(summary)
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - Controls

    func cancel() async {
        guard let harness = activeHarness, let run = activeRun else { return }
        try? await harness.cancel(run)
        activeRun?.status = .cancelled
        let summary = AgentSummarizer.summarize(result, status: .cancelled)
        lastSummary = summary
        emit(summary)
        eventTask?.cancel()
        eventTask = nil
    }

    /// Answer an `awaitingInput` confirmation. Declining cancels the run (safety default).
    func respondToConfirmation(approved: Bool) async {
        guard let harness = activeHarness, let run = activeRun, run.status == .awaitingInput else { return }
        try? await harness.respondToInput(run, approved: approved)
        awaitingInputPrompt = nil
        if approved {
            activeRun?.status = .running
            emit("Okay, proceeding.")
        } else {
            activeRun?.status = .cancelled
            lastSummary = AgentSummarizer.summarize(result, status: .cancelled)
            emit("Okay, I won't proceed.")
            eventTask?.cancel()
            eventTask = nil
        }
    }

    /// One spoken line describing the current state (for "agent status").
    func currentStatusLine() -> String {
        guard let run = activeRun else { return "No agent run is active." }
        switch run.status {
        case .queued:        return "The agent run is queued."
        case .running:       return "The agent is working on \(run.project ?? "your task")."
        case .awaitingInput: return awaitingInputPrompt ?? "The agent is waiting for your confirmation."
        case .completed:     return lastSummary ?? "The agent run is complete."
        case .failed:        return lastSummary ?? "The agent run failed."
        case .cancelled:     return "The agent run was cancelled."
        }
    }

    private func emit(_ line: String) {
        spokenLog.append(line)
        speak(line)
    }
}

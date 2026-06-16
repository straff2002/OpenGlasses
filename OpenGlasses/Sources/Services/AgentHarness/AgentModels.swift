import Foundation

/// Which remote agent backend a run targets (Plan N). Harness-agnostic: adapters translate their
/// native protocol into the shared `AgentEvent` stream, so one summarizer/narrator serves them all.
enum AgentHarnessKind: String, CaseIterable, Codable, Identifiable {
    case openclaw       // OpenClaw gateway — the real, phone-only path today
    case codexCloud     // OpenAI Codex cloud agent — adapter pending trigger verification
    case claudeRemote   // Claude Code via routines/web — adapter pending verification
    case custom         // user-supplied URL + token + field mapping

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openclaw:     return "OpenClaw"
        case .codexCloud:   return "OpenAI Codex (cloud)"
        case .claudeRemote: return "Claude Code (remote)"
        case .custom:       return "Custom endpoint"
        }
    }
}

/// Lifecycle of a single remote agent run, normalized across harnesses.
enum AgentRunStatus: String, Codable, Equatable {
    case queued
    case running
    case awaitingInput   // paused for a spoken/HUD confirmation (e.g. before push/PR)
    case completed
    case failed
    case cancelled

    /// No further events expected.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .awaitingInput: return false
        }
    }

    /// Map a gateway/endpoint status string to a case, tolerant of common spellings. Shared by every
    /// adapter (OpenClaw, Custom, …) so status parsing lives in one place.
    static func parse(_ raw: String?) -> AgentRunStatus? {
        switch raw?.lowercased() {
        case "queued", "pending":            return .queued
        case "running", "in_progress":       return .running
        case "awaiting_input", "waiting":    return .awaitingInput
        case "completed", "done", "success": return .completed
        case "failed", "error":              return .failed
        case "cancelled", "canceled":        return .cancelled
        default:                             return nil
        }
    }
}

/// One dispatched remote agent task.
struct AgentRun: Identifiable, Equatable {
    let id: String
    let harness: AgentHarnessKind
    let prompt: String
    let project: String?
    var status: AgentRunStatus
    let startedAt: Date

    init(id: String, harness: AgentHarnessKind, prompt: String, project: String?,
         status: AgentRunStatus = .queued, startedAt: Date) {
        self.id = id
        self.harness = harness
        self.prompt = prompt
        self.project = project
        self.status = status
        self.startedAt = startedAt
    }
}

/// Normalized event every adapter emits — the payoff of the abstraction: write the summarizer and
/// narrator once, against these, and every harness benefits.
enum AgentEvent: Equatable {
    case started(AgentRun)
    case progress(String)
    case fileCreated(String)
    case fileModified(String)
    case commandRun(command: String, ok: Bool)
    case prOpened(url: String)
    case pushed
    case awaitingInput(prompt: String)   // agent needs the user to confirm before continuing
    case assistantText(String)
    case completed(AgentRunResult)
    case error(String)
}

/// Aggregated outcome of a run — what the summarizer turns into a spoken line.
struct AgentRunResult: Equatable {
    var filesCreated: [String] = []
    var filesModified: [String] = []
    var commandsRun: [String] = []
    var prURL: String?
    var pushed = false
    var finalText: String?
    var error: String?

    /// Fold one event into the running result. Pure and deterministic, so event→result aggregation
    /// is unit-testable without a live harness. `started`/`progress`/`awaitingInput`/`completed`
    /// don't mutate the tallies (they drive narration/state, not the outcome record).
    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .fileCreated(let path):
            if !filesCreated.contains(path) { filesCreated.append(path) }
        case .fileModified(let path):
            if !filesModified.contains(path) { filesModified.append(path) }
        case .commandRun(let command, _):
            commandsRun.append(command)
        case .prOpened(let url):
            prURL = url
        case .pushed:
            pushed = true
        case .assistantText(let text):
            finalText = text
        case .error(let message):
            error = message
        case .completed(let result):
            // A terminal result from the harness supersedes our running tally.
            self = result
        case .started, .progress, .awaitingInput:
            break
        }
    }

    /// Build a result from a sequence of events (convenience for tests / replay).
    static func reduce(_ events: [AgentEvent]) -> AgentRunResult {
        var result = AgentRunResult()
        for event in events { result.apply(event) }
        return result
    }
}

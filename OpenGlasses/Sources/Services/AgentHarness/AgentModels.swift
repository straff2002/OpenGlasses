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

    /// Case-insensitive lookup ("codexcloud" → .codexCloud). The `switch_harness` tool lowercases
    /// what the LLM passes, which can never equal a camelCase raw value (BM P5).
    static func matching(_ raw: String) -> AgentHarnessKind? {
        let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue.lowercased() == folded }
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
    /// The run is waiting on the wearer. Carries a **question with a stable identity**, not a
    /// bare prompt (Plan FE P1): text equality can neither suppress a repeat nor recognise a
    /// genuinely new question worded the same way.
    case awaitingInput(AgentQuestion)
    case assistantText(String)
    /// Terminal: the run finished normally. Three separate terminal cases rather than one
    /// `completed` plus a flag, because collapsing them is exactly how a remote **cancellation**
    /// came to be spoken as success (Plan FE P0).
    case completed(AgentRunResult)
    /// Terminal: the harness says the run failed, with whatever it reported about it.
    case failed(AgentRunResult)
    /// Terminal: the run was cancelled at the far end (or by us). Never narrated as "done".
    case cancelled(AgentRunResult)
    /// Mid-run error the harness reported while it was still talking to us.
    case error(String)
    /// Our ability to *observe* the run changed — not a claim about the run itself. A lost
    /// connection says we stopped knowing; it never says the agent failed or was cancelled.
    case connection(AgentConnectionState)
}

/// Which outcome fields the harness actually **reported**, as distinct from which came back empty.
///
/// The distinction is the whole point of Plan FE P0: an endpoint that says nothing about files is
/// unknown, and narrating that as "no files changed" is a claim we have no evidence for.
struct AgentResultFields: OptionSet, Equatable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let filesCreated  = AgentResultFields(rawValue: 1 << 0)
    static let filesModified = AgentResultFields(rawValue: 1 << 1)
    static let commandsRun   = AgentResultFields(rawValue: 1 << 2)
    static let pushed        = AgentResultFields(rawValue: 1 << 3)
    static let prURL         = AgentResultFields(rawValue: 1 << 4)
    static let finalText     = AgentResultFields(rawValue: 1 << 5)
    static let error         = AgentResultFields(rawValue: 1 << 6)

    /// The fields that describe what the run changed.
    static let changes: AgentResultFields = [.filesCreated, .filesModified, .commandsRun, .pushed, .prURL]
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
    /// Which of the above the harness actually told us about (Plan FE P0). Empty means we were
    /// told nothing — *unknown*, not "nothing happened".
    var reported: AgentResultFields = []

    /// Anything at all in this record? A completely blank record is a non-report, and a terminal
    /// non-report must not be allowed to erase a tally we built from events we actually saw.
    var isBlank: Bool {
        reported.isEmpty && filesCreated.isEmpty && filesModified.isEmpty && commandsRun.isEmpty
            && prURL == nil && !pushed && finalText == nil && error == nil
    }

    /// True only when the harness reported **both** file lists and both were empty — the one case
    /// where "no file changes" is a fact rather than a guess.
    var reportedNoFileChanges: Bool {
        reported.contains(.filesCreated) && reported.contains(.filesModified)
            && filesCreated.isEmpty && filesModified.isEmpty
    }

    /// Fold one event into the running result. Pure and deterministic, so event→result aggregation
    /// is unit-testable without a live harness. `started`/`progress`/`awaitingInput`/`completed`
    /// don't mutate the tallies (they drive narration/state, not the outcome record).
    mutating func apply(_ event: AgentEvent) {
        switch event {
        case .fileCreated(let path):
            if !filesCreated.contains(path) { filesCreated.append(path) }
            reported.insert(.filesCreated)
        case .fileModified(let path):
            if !filesModified.contains(path) { filesModified.append(path) }
            reported.insert(.filesModified)
        case .commandRun(let command, _):
            commandsRun.append(command)
            reported.insert(.commandsRun)
        case .prOpened(let url):
            prURL = url
            reported.insert(.prURL)
        case .pushed:
            pushed = true
            reported.insert(.pushed)
        case .assistantText(let text):
            finalText = text
            reported.insert(.finalText)
        case .error(let message):
            error = message
            reported.insert(.error)
        case .completed(let result), .failed(let result), .cancelled(let result):
            // A terminal result from the harness supersedes our running tally — unless it reports
            // nothing at all, in which case the events we actually saw are the better record.
            if !result.isBlank { self = result }
        case .started, .progress, .awaitingInput, .connection:
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

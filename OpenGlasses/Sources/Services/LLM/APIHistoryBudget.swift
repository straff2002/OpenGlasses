import Foundation

/// Plan GB P5 — a history budget for the pay-per-token API providers (OpenAI and the other
/// Chat Completions providers, Anthropic, Gemini REST).
///
/// # Why
///
/// API history was never budgeted: FM's `RequestContextBudget` bounds the ChatGPT subscription
/// only, and the legacy compactor waits for an 80k estimate that under-counted images. The field
/// tester's requests grew from 39 to 159 messages across two jobs, each one re-sent — and billed —
/// in full on every turn and every tool round-trip.
///
/// # The rule
///
/// Selection works on a **request copy**; the saved conversation and `conversationHistory` are never
/// touched (FM: compaction never removes saved messages). Messages before the current job's first
/// turn (`floor`) are left out, so each job starts fresh. Then complete older user exchanges are
/// dropped oldest first — cut at the same seams as `RequestContextBudget`
/// (`nextExchangeBoundary`) — until the estimate fits the allowance. The current user turn and every
/// tool call and result since it are protected as a unit and are never dropped, even over budget.
/// Pure and table-tested.
enum APIHistoryBudget {

    /// The default allowance in estimated tokens (plan: 12–16k, a setting).
    static let defaultAllowance = 14_000

    struct Selection {
        let history: [[String: Any]]
        /// Older messages left out of the request — before the job floor or over budget.
        let omittedMessages: Int
        let estimatedTokens: Int
    }

    /// - Parameters:
    ///   - protectedStart: index in `history` of the current user turn.
    ///   - floor: index of the current job's first message; 0 when no job boundary applies.
    ///   - allowance: estimated-token allowance for the history; 0 or less disables trimming.
    static func select(history: [[String: Any]], protectedStart: Int, floor: Int = 0,
                       allowance: Int) -> Selection {
        let protected = min(max(0, protectedStart), history.count)
        // The floor never cuts into the protected turn.
        let start = min(max(0, floor), protected)
        var selected = Array(history[start...])
        var boundary = protected - start
        var omitted = start
        guard allowance > 0 else {
            return Selection(history: selected, omittedMessages: omitted,
                             estimatedTokens: HistoryHygiene.estimatedTokens(selected))
        }
        var estimate = HistoryHygiene.estimatedTokens(selected)
        while estimate > allowance, boundary > 0 {
            let next = RequestContextBudget.nextExchangeBoundary(in: selected, remainingOld: boundary)
            guard next > 0 else { break }
            selected.removeFirst(next)
            boundary -= next
            omitted += next
            estimate = HistoryHygiene.estimatedTokens(selected)
        }
        return Selection(history: selected, omittedMessages: omitted, estimatedTokens: estimate)
    }

    /// One line for the volatile tail when older messages were left out, so the model does not
    /// infer that an absent exchange never happened. Nil when nothing was omitted.
    static func omissionNote(_ omitted: Int) -> String? {
        guard omitted > 0 else { return nil }
        return "[Working context: \(omitted) older messages are not included in this request. The saved conversation is unchanged. Do not infer missing results; current job state takes precedence over older conversation.]"
    }
}

/// Where the current job's conversation starts in the model's in-memory history (Plan GB P5,
/// "history starts fresh per job"). The job boundary itself keeps the model's history today —
/// `GuidedJobFlow` clears it only when the bound thread was deleted — so the request copy applies
/// the boundary instead. Pure state machine: the service reports each turn's start and the active
/// job id before and after the turn.
struct JobHistoryFloor: Equatable {
    private(set) var floor = 0
    private(set) var lastSessionId: String?

    /// A turn is starting at `turnStart` with `sessionId` active. A job that became active between
    /// turns (started from the Job tab) begins here.
    mutating func turnStarted(at turnStart: Int, sessionId: String?) {
        if let sessionId, sessionId != lastSessionId { floor = turnStart }
        lastSessionId = sessionId ?? lastSessionId
    }

    /// The turn that started at `turnStart` finished with `sessionId` active. A job started by this
    /// very turn (a spoken "start a job") begins with the turn that started it.
    mutating func turnFinished(startedAt turnStart: Int, sessionId: String?) {
        if let sessionId, sessionId != lastSessionId { floor = turnStart }
        lastSessionId = sessionId ?? lastSessionId
    }

    /// History was replaced wholesale (a thread loaded or cleared) while `sessionId` is active: the
    /// loaded history *is* this job's conversation, so nothing in it is before the floor.
    mutating func historyReplaced(sessionId: String?) {
        floor = 0
        lastSessionId = sessionId
    }

    /// The legacy compactor replaced the oldest messages with `insertedSummary` summary messages,
    /// taking the history from `before` to `after` messages (it always keeps the newest suffix). A
    /// floor inside the compacted part falls to 0: the summary mixes both sides of it.
    mutating func historyCompacted(before: Int, after: Int, insertedSummary: Int) {
        let removedFromFront = before - (after - insertedSummary)
        floor = floor >= removedFromFront ? floor - removedFromFront + insertedSummary : 0
    }

    /// The floor clamped to the history's current size.
    func floor(historyCount: Int) -> Int { min(floor, historyCount) }
}

import Foundation

/// Plan KK P2 — what the last cloud request carried, read where the request copy was built, for
/// the summary pass's coverage count. Counts and a date only: no text leaves `LLMService` this way.
struct TimelineRequestReading: Equatable, Sendable {
    /// Real user turns the request kept, counted from its tail.
    let keptUserTurns: Int
    /// Real user turns in the whole in-memory history the request was cut from.
    let historyUserTurns: Int
    /// When the current job's history starts, or nil when no job floor applies. The floor is an
    /// index into the in-memory history; this is the time of the turn that set it.
    let floorDate: Date?

    /// The wearer's turns in a provider history, which also holds tool calls, tool results and the
    /// app's own notes.
    ///
    /// A real turn is a user message whose content is plain text, the seam the request budgets
    /// already cut at (`RequestContextBudget.nextExchangeBoundary`). That leaves out tool results
    /// (a `tool_result` array on Anthropic, `role: tool` or `function` elsewhere), a tool's photo
    /// riding as a user message, and a turn the wearer sent with a photo. The app's own notes are
    /// plain text too, so they are named and left out: everything the app writes as a user
    /// message opens with "[" (a compaction or replay summary, the memory review, the offline
    /// note), and the tool loop's two re-ask lines are matched exactly.
    ///
    /// The count errs low on purpose. A turn missed here reads as having left the request, so it
    /// is summarised while the model still has it: an overlap, which only wastes a few tokens. A
    /// note counted as a turn would do the opposite and leave a gap, which is the defect.
    static func realUserTurns(in history: [[String: Any]]) -> Int {
        history.reduce(0) { count, message in
            guard message["role"] as? String == "user",
                  let text = message["content"] as? String else { return count }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("["),
                  !appNotes.contains(trimmed) else { return count }
            return count + 1
        }
    }

    /// The tool loop's re-ask lines, which ride as user messages and are not the wearer's.
    private static let appNotes: Set<String> = [StallReplyPolicy.nudge, StallReplyPolicy.silenceNudge]
}

import Foundation

/// Turns a normalized agent run into spoken English (Plan N). Pure and harness-agnostic — written
/// once, it serves every adapter, since they all emit `AgentEvent`/`AgentRunResult`. No I/O, no LLM,
/// fully unit-testable. Prior art: `MeetingSummaryTool`'s extraction, but deterministic here.
enum AgentSummarizer {

    /// Hard cap on a spoken line so TTS stays brief on the glasses.
    static let maxLength = 320

    /// The final spoken line for a finished run. `status` distinguishes completed / failed /
    /// cancelled; `result` carries the tallies. Completed runs end with "Done."
    static func summarize(_ result: AgentRunResult, status: AgentRunStatus) -> String {
        switch status {
        case .cancelled:
            return "Cancelled the agent run."
        case .failed:
            let detail = result.error.map { ": \($0)" } ?? ""
            return cap("The agent run failed\(detail).")
        case .completed, .queued, .running, .awaitingInput:
            if let error = result.error {
                return cap("The agent run failed: \(error).")
            }
            return cap(completedLine(result))
        }
    }

    private static func completedLine(_ result: AgentRunResult) -> String {
        var clauses: [String] = []
        if !result.filesCreated.isEmpty {
            clauses.append("created \(countPhrase(result.filesCreated.count, "file"))")
        }
        if !result.filesModified.isEmpty {
            clauses.append("modified \(countPhrase(result.filesModified.count, "file"))")
        }
        if !result.commandsRun.isEmpty {
            clauses.append("ran \(countPhrase(result.commandsRun.count, "command"))")
        }
        if result.pushed {
            clauses.append("pushed the changes")
        }
        if result.prURL != nil {
            clauses.append("opened a pull request")
        }

        if clauses.isEmpty {
            // No structured changes — fall back to the agent's own closing words, else a default.
            if let text = result.finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.hasSuffix(".") ? "\(text) Done." : "\(text). Done."
            }
            return "The agent finished with no file changes. Done."
        }
        return "The agent \(joinClauses(clauses)). Done."
    }

    /// A brief spoken line for a key in-flight event, or `nil` for events not worth narrating
    /// individually (per-file changes are tallied and summarized at the end instead).
    static func narration(for event: AgentEvent) -> String? {
        switch event {
        case .progress(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : cap(t)
        case .commandRun(let command, let ok):
            return ok ? nil : cap("A command failed: \(command).")
        case .prOpened:
            return "Opened a pull request."
        case .pushed:
            return "Pushed the changes."
        case .awaitingInput(let prompt):
            return cap(prompt)
        case .error(let message):
            return cap("The agent hit an error: \(message).")
        case .started, .fileCreated, .fileModified, .assistantText, .completed:
            return nil
        }
    }

    // MARK: - Helpers

    /// "one file" / "two files" / "5 files" — small counts as words for natural speech.
    static func countPhrase(_ n: Int, _ noun: String) -> String {
        let plural = n == 1 ? noun : noun + "s"
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let number = (n >= 0 && n < words.count) ? words[n] : String(n)
        return "\(number) \(plural)"
    }

    /// Join clauses with commas and a trailing "and" before the last (Oxford-free for speech).
    static func joinClauses(_ clauses: [String]) -> String {
        switch clauses.count {
        case 0: return ""
        case 1: return clauses[0]
        case 2: return "\(clauses[0]) and \(clauses[1])"
        default:
            let head = clauses.dropLast().joined(separator: ", ")
            return "\(head), and \(clauses.last!)"
        }
    }

    /// Cap a spoken line at `maxLength`, truncating on a word boundary with an ellipsis.
    static func cap(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let slice = text.prefix(maxLength - 1)
        if let lastSpace = slice.lastIndex(of: " ") {
            return slice[slice.startIndex..<lastSpace] + "…"
        }
        return slice + "…"
    }
}

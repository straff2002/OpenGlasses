import Foundation

/// Turns a normalized agent run into spoken English (Plan N). Pure and harness-agnostic — written
/// once, it serves every adapter, since they all emit `AgentEvent`/`AgentRunResult`. No I/O, no LLM,
/// fully unit-testable. Prior art: `MeetingSummaryTool`'s extraction, but deterministic here.
enum AgentSummarizer {

    /// Hard cap on a spoken line so TTS stays brief on the glasses.
    static let maxLength = 320

    /// Who stopped a cancelled run. We cancelled it on the wearer's instruction, or it stopped at
    /// the far end — two different sentences, and saying the first when the second happened puts
    /// words in the wearer's mouth.
    enum CancellationOrigin { case local, remote }

    /// The final spoken line for a finished run. `status` distinguishes completed / failed /
    /// cancelled; `result` carries the tallies. Completed runs end with "Done."
    static func summarize(_ result: AgentRunResult, status: AgentRunStatus,
                          cancellation: CancellationOrigin = .remote) -> String {
        switch status {
        case .cancelled:
            switch cancellation {
            case .local:  return "Cancelled the agent run."
            case .remote: return cap(cancelledLine(result))
            }
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

    /// A run that stopped at the far end. Never "Done." — it did not finish.
    static func cancelledLine(_ result: AgentRunResult) -> String {
        let clauses = changeClauses(result)
        if clauses.isEmpty { return "The agent run was cancelled before it finished." }
        return "The agent run was cancelled. Before it stopped it \(joinClauses(clauses))."
    }

    /// The clauses for whatever the harness actually reported changing — silence about a field is
    /// silence, never a claim that nothing happened there.
    static func changeClauses(_ result: AgentRunResult) -> [String] {
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
        if result.prURL != nil || result.reported.contains(.prURL) {
            clauses.append("opened a pull request")
        }
        return clauses
    }

    private static func completedLine(_ result: AgentRunResult) -> String {
        let clauses = changeClauses(result)
        if clauses.isEmpty {
            // No structured changes — fall back to the agent's own closing words…
            if let text = result.finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.hasSuffix(".") ? "\(text) Done." : "\(text). Done."
            }
            // …and otherwise say which of the two we're in. "No file changes" is a fact only when
            // the harness reported both file lists and both were empty; being told nothing is
            // being told nothing, and narrating that as "nothing changed" invents the evidence.
            return result.reportedNoFileChanges
                ? "The agent finished with no file changes. Done."
                : "The agent finished; it didn't report what changed."
        }
        return "The agent \(joinClauses(clauses)). Done."
    }

    // MARK: - Contact (Plan FE P0)

    /// The one line spoken when we stop being able to follow a run. Every wording here is about the
    /// *endpoint*: the run may well still be going, and we must not imply it failed or was stopped.
    static func line(for loss: AgentContactLoss) -> String {
        switch loss {
        case .network:
            return "I've lost contact with the agent endpoint, so I can't follow the run any more. It may still be running."
        case .auth:
            return "The agent endpoint rejected my credentials, so I've stopped checking on the run. Check the token in Settings."
        case .endpoint:
            return "The agent endpoint stopped accepting my status checks, so I've stopped following the run."
        case .unknownStatus(let raw):
            let label = AgentResultMapping.statusLabel(raw)
            return label.isEmpty
                ? "The agent endpoint stopped reporting a status I recognise, so I've stopped following the run."
                : cap("The agent endpoint keeps reporting a status I don't recognise: \(label). I've stopped following the run.")
        case .noStatusEndpoint:
            return "There's no status address set for this agent, so I can't tell you how the run is going."
        }
    }

    /// The "agent status" answer once contact is lost — what happened, when, and the last thing we
    /// actually knew. Never upgraded into a guess about the present.
    static func statusLine(afterContactLost loss: AgentContactLoss, at time: String,
                           lastKnown: AgentRunStatus) -> String {
        let last: String
        switch lastKnown {
        case .queued:        last = "the run was still queued"
        case .running:       last = "the agent was working"
        case .awaitingInput: last = "the agent was waiting for your confirmation"
        case .completed, .failed, .cancelled: last = "the run had already finished"
        }
        let cause: String
        switch loss {
        case .auth:             cause = "The agent endpoint rejected my credentials at \(time)"
        case .noStatusEndpoint: return "There's no status address set for this agent, so I can't check on the run. The last I knew, \(last)."
        case .unknownStatus:    cause = "The agent endpoint stopped reporting a status I recognise at \(time)"
        case .endpoint:         cause = "The agent endpoint stopped accepting my status checks at \(time)"
        case .network:          cause = "I lost contact with the agent endpoint at \(time)"
        }
        return cap("\(cause), so I stopped checking. The last I knew, \(last).")
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
        case .error(let message):
            return cap("The agent hit an error: \(message).")
        case .started, .fileCreated, .fileModified, .assistantText, .awaitingInput,
             .completed, .failed, .cancelled, .connection:
            // Terminal events, connection changes and questions are narrated by the session (one
            // final line, one contact line, one ask per question identity) — narrating them here
            // too would say everything twice, and would re-announce every polled repeat.
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

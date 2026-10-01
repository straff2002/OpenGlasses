import Foundation

/// Carries the conversation across the handoff in both directions (Plan GE P0).
///
/// * **Outbound (cloud → phone):** the on-device model has a small window, so it gets the newest
///   turns that fit its budget, oldest dropped first. When the history already carries a summary of
///   earlier turns (the compactor's line), that summary rides in front if it fits — no new model
///   call is made to write one.
/// * **Inbound (phone → cloud):** the turns answered on the phone stay in the history like any
///   other (and are marked `answeredOnDevice` in the conversation store). The cloud model is told,
///   in one line, which answers came from the smaller model so it can give them a second look.
///
/// Pure: token counts are an estimate passed in, so the window rule is tested headlessly.
enum HandoffTranscriptBridge {

    typealias Turn = (role: String, content: String)

    /// Prefixes the history compactors put on the summary they leave behind.
    static let summaryPrefixes = ["[Earlier conversation context", "[Conversation summary"]

    /// Most turns ever carried outbound, whatever the budget says: prefill time grows with every
    /// turn, and a phone-sized model gains little from a long tail.
    static let maxOutboundTurns = 12

    /// Rough token estimate — the same four-characters-per-token rule the compactor uses.
    static func estimatedTokens(_ text: String) -> Int { max(1, text.count / 4) }

    static func isSummary(_ turn: Turn) -> Bool {
        summaryPrefixes.contains { turn.content.hasPrefix($0) }
    }

    /// The window the on-device model gets.
    ///
    /// - Parameters:
    ///   - history: the conversation so far, oldest first.
    ///   - budgetTokens: tokens available for history (the model's prompt budget minus the system
    ///     prompt and the current turn).
    /// - Returns: the summary line (if one already exists in the history and fits) followed by the
    ///   newest turns that fit, oldest first.
    static func outboundWindow(history: [Turn], budgetTokens: Int,
                               maxTurns: Int = maxOutboundTurns,
                               estimate: (String) -> Int = estimatedTokens) -> [Turn] {
        guard budgetTokens > 0 else { return [] }
        let summary = history.last(where: isSummary)
        let conversational = history.filter { !isSummary($0) }

        let everything = newestFitting(conversational, budget: budgetTokens, maxTurns: maxTurns,
                                       estimate: estimate)
        guard everything.count < conversational.count else { return everything }

        // Something had to go. When the compactor already left a summary of the earlier turns, it
        // takes its place in front — given at most half the budget, so the recent turns still lead.
        if let summary {
            let cost = estimate(summary.content)
            if cost <= budgetTokens / 2 {
                return [summary] + newestFitting(conversational, budget: budgetTokens - cost,
                                                 maxTurns: maxTurns, estimate: estimate)
            }
        }
        return everything
    }

    /// The newest turns that fit `budget`, oldest first, opening on a user turn when one is there.
    private static func newestFitting(_ turns: [Turn], budget: Int, maxTurns: Int,
                                      estimate: (String) -> Int) -> [Turn] {
        var kept: [Turn] = []
        var used = 0
        for turn in turns.reversed() {
            guard kept.count < maxTurns else { break }
            let cost = estimate(turn.content)
            guard used + cost <= budget else { break }
            kept.append(turn)
            used += cost
        }
        kept.reverse()
        // A window that opens on the assistant's half of an exchange reads as the model talking
        // to itself; start on a user turn when one is in the window.
        if let firstUser = kept.firstIndex(where: { $0.role == "user" }), firstUser > 0 {
            kept.removeFirst(firstUser)
        }
        return kept
    }

    // MARK: - Inbound

    /// One exchange answered on the phone, as the inbound note needs it.
    struct OnDeviceAnswer: Equatable {
        var question: String
        var answer: String
    }

    /// Longest stretch of a question quoted in the note.
    static let quotedQuestionLength = 60
    /// Most questions quoted by name; any more are counted.
    static let maxQuotedQuestions = 3

    /// The one-line note for the cloud model on return, or nil when nothing was answered on the
    /// phone.
    static func inboundNote(_ answers: [OnDeviceAnswer]) -> String? {
        guard !answers.isEmpty else { return nil }
        let quoted = answers.suffix(maxQuotedQuestions).map { "\u{201C}\(clip($0.question))\u{201D}" }
        let count = answers.count
        let lead = count == 1
            ? "[System note: while the connection was down, 1 answer in this conversation was given by a smaller on-device model and may deserve a second look"
            : "[System note: while the connection was down, \(count) answers in this conversation were given by a smaller on-device model and may deserve a second look"
        let more = count > quoted.count ? " and \(count - quoted.count) more" : ""
        return lead + " — the replies to " + quoted.joined(separator: ", ") + more
            + ". Correct anything that was wrong if it comes up; don't repeat them otherwise.]"
    }

    private static func clip(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > quotedQuestionLength else { return flat }
        return String(flat.prefix(quotedQuestionLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

import Foundation

/// Plan CB P1 — how asynchronous content is put into the assistant's mouth.
///
/// Three rules, each earned from a specific failure mode:
///
/// 1. **The acknowledgement is an instruction, not a sentence.** A fixed string gets spoken
///    verbatim and sounds like a status readout ("Still working on that..."). Asking the model to
///    acknowledge *in its own words* produces cover that fits the conversation it is already
///    having.
/// 2. **The instruction must forbid answering from memory.** A model handed "task started" with no
///    further constraint confabulates the result — invents the calendar, guesses the number.
/// 3. **A late result is framed as the answer to what was asked.** Delivered as a bare
///    notification, it gets announced as fresh news seconds after the question. It carries its
///    question with it.
///
/// Direct mode (no live session) has no model to phrase things, so it keeps deterministic strings —
/// but they live here too, so the two modes cannot drift apart.
enum AsyncDeliveryPhrasing {

    /// Instruction injected when a delegated task will take a while: the model acknowledges
    /// naturally and is explicitly barred from inventing the outcome.
    static func acknowledgementInstruction(taskDescription: String?) -> String {
        let task = taskDescription.map { " (\($0))" } ?? ""
        return """
        A background task\(task) is still running. Briefly acknowledge, in your own words and \
        in the flow of the current conversation, that you're still working on it. Do not answer \
        the request from memory or guess at the result — the real result will arrive shortly.
        """
    }

    /// Markers that fence the quoted result. Delimiters rather than prose because the model has
    /// to tell our framing from the task's own words, and prose alone doesn't survive a result
    /// that happens to be written in the second person.
    static let resultBeginMarker = "---BEGIN RESULT---"
    static let resultEndMarker = "---END RESULT---"

    /// Instruction injected when a deferred result lands: framed as the answer to the original
    /// question, so the model presents it as such rather than as unprompted news.
    ///
    /// Both live wires deliver an injection as a **user turn**, which is what makes the layout
    /// load-bearing. Field-observed: with the raw result last, a task whose answer ended in an
    /// assistant-style sign-off ("Let me know if you need anything else!") read to the model as
    /// the *user* closing the conversation — so it replied "You're welcome!" and never spoke the
    /// result at all. Hence: the result is fenced as quoted material, it is said in as many words
    /// that the wearer did not say it, and the delivery instruction is the last line, where a
    /// turn's actual intent lives.
    static func resultInstruction(question: String?, answer: String) -> String {
        let asked = question.map { "The user earlier asked: \"\($0)\". " } ?? ""
        let quoted = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(asked)The result of that background task has just arrived. Everything between the \
        markers below is quoted material from that task — it is NOT something the user just said \
        to you, so do not reply to it, thank it, or treat its closing words as the user's.

        \(resultBeginMarker)
        \(quoted)
        \(resultEndMarker)

        Deliver the quoted result now, in your own voice, as the answer to what was asked — not \
        as a new notification.
        """
    }

    /// Deterministic Direct-mode fallback for the long-running-tool timer (no model available to
    /// phrase it). Varies with elapsed time so repeats don't sound like a stuck loop.
    static func directModeStillWorking(elapsedSeconds: Int) -> String {
        elapsedSeconds <= 10 ? "Still working on that." : "Still working — almost there."
    }
}

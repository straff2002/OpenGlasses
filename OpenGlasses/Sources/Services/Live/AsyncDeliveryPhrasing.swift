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

    /// Instruction injected when a deferred result lands: framed as the answer to the original
    /// question, so the model presents it as such rather than as unprompted news.
    static func resultInstruction(question: String?, answer: String) -> String {
        let asked = question.map { "The user earlier asked: \"\($0)\". " } ?? ""
        return """
        \(asked)The result of that background task has just arrived. Deliver it now as the \
        answer to what was asked — not as a new notification. Result:
        \(answer)
        """
    }

    /// Deterministic Direct-mode fallback for the long-running-tool timer (no model available to
    /// phrase it). Varies with elapsed time so repeats don't sound like a stuck loop.
    static func directModeStillWorking(elapsedSeconds: Int) -> String {
        elapsedSeconds <= 10 ? "Still working on that." : "Still working — almost there."
    }
}

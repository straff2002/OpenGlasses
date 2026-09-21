import Foundation

/// Whether a `new_topic` tool call is backed by the wearer actually asking for a reset.
///
/// A model deciding to wipe the conversation is not like a model deciding to read the clock. The
/// reset stops speech mid-sentence, retires every backend's context and opens a new saved thread,
/// and none of that is undoable from the glasses. The tool's own description invites the call on
/// "start over" and "start fresh", and a field build (407) duly called it on *"start a new field
/// service session as signed job 1005"* — the reply was cut off a second in, the job's first turn
/// was filed in a thread of its own, and nothing told the technician why.
///
/// So the gate: the words the wearer actually said have to read as a bare reset command, judged by
/// the same `ConversationClassifier` test that decides whether to reset without an LLM turn at
/// all. A model that calls the tool on anything else is told plainly that nothing was reset and
/// that it should carry on, which costs one tool round trip and keeps the conversation.
enum NewTopicRequestGate {

    private static let classifier = ConversationClassifier()

    /// Whether `utterance` asks for the conversation to be cleared.
    static func isResetRequest(_ utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return classifier.isBareResetRequest(trimmed)
    }

    /// What the model is told when the call is refused.
    ///
    /// Phrased as a fact about what happened rather than an instruction about what to do, because
    /// the model's next move belongs to the model: the point is that it must not tell the wearer
    /// their conversation was cleared when it was not.
    static let refusal = """
    No reset happened — nothing was cleared. This request was not a conversation reset: \
    "start a new <something>" (a session, a job, a note, a timer) asks to start that thing, not \
    to clear the chat. Do not say the conversation was reset. Continue answering the request, \
    using the right tool for it if there is one.
    """
}

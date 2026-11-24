import Foundation

/// A finished wearer turn in a live session, as the app's backstops read it.
struct LiveWearerTurn: Equatable {
    /// Everything the wearer said in the turn.
    let text: String
    /// Whether the model said anything in the turn.
    let modelReplied: Bool
    /// The conversation-reset generation the turn began under, when it is known.
    let resetGeneration: UInt64?
    /// The guided job flow took the words as the answer to one of its own questions.
    let consumedByJob: Bool
}

/// The live-mode backstop for a bare "new topic".
///
/// In Direct mode the classifier routes a bare reset phrase straight to the reset (Tier 0). In a
/// live session the wearer talks to the remote model, and the conversation was only reset if the
/// model called `new_topic`. This reads the finished wearer turn with the **same** Tier-0 test
/// (`ConversationClassifier.isBareNewTopicCommand(_:)`, one phrase list) and asks for the reset the
/// model forgot.
///
/// The live microphone hears the whole room, so the gates follow the live goodbye backstop
/// (`LiveVoiceEndPolicy.backstopApplies`), not Direct's wake-word turn:
/// - a model that stayed silent decided it was not being spoken to, so nothing is reset;
/// - during a job the model's tool alone decides: "let's start over" to a customer must not
///   retire the job's conversation;
/// - words the guided job flow took as an answer were an answer, not a command;
/// - an interpreter's words are the other person's as often as the wearer's (the session never
///   reports an interpreter turn here, and the gate is kept so it cannot start to).
///
/// The model may also call `new_topic` for the same words. `ConversationResetCoordinator`
/// absorbs the second request: see `requestLiveBackstopReset(turnGeneration:)`.
enum LiveNewTopicBackstop {

    static func applies(_ turn: LiveWearerTurn, jobActive: Bool, interpreting: Bool) -> Bool {
        guard turn.modelReplied, !turn.consumedByJob, !jobActive, !interpreting else { return false }
        return ConversationClassifier.isBareNewTopicCommand(turn.text)
    }
}

/// Pairs a complete transcript with the end of its turn, for a provider that sends the wearer's
/// words once per turn (the JSON realtime protocols). The transcript can arrive before the turn
/// ends or after it, and whether the model replied is only known at the end.
///
/// A new turn starting (the server hearing the wearer again) lets go of an ended turn still
/// waiting for its words, and of words still waiting for their turn's end: whatever lands after
/// that cannot be told apart from the next turn's, which is the same rule the session applies to
/// its goodbye check.
struct CompleteTranscriptPairing: Equatable {

    private struct Words: Equatable {
        let text: String
        let resetGeneration: UInt64?
        let consumedByJob: Bool
    }

    private var words: Words?
    /// The turn ended before its words arrived; whether the model replied in it.
    private var endedReplied: Bool?

    /// The turn's whole transcript arrived.
    mutating func transcriptArrived(_ text: String, resetGeneration: UInt64?,
                                    consumedByJob: Bool) -> LiveWearerTurn? {
        if let replied = endedReplied {
            endedReplied = nil
            return LiveWearerTurn(text: text, modelReplied: replied,
                                  resetGeneration: resetGeneration, consumedByJob: consumedByJob)
        }
        words = Words(text: text, resetGeneration: resetGeneration, consumedByJob: consumedByJob)
        return nil
    }

    /// The provider said the turn is complete.
    mutating func turnEnded(modelReplied: Bool) -> LiveWearerTurn? {
        guard let words else {
            endedReplied = modelReplied
            return nil
        }
        self.words = nil
        return LiveWearerTurn(text: words.text, modelReplied: modelReplied,
                              resetGeneration: words.resetGeneration,
                              consumedByJob: words.consumedByJob)
    }

    /// The server heard the wearer start a new utterance.
    mutating func speechStarted() {
        words = nil
        endedReplied = nil
    }
}

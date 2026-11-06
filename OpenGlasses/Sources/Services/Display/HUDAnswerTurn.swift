import Foundation

/// One turn's spoken answer, collected for the answer card (Plan KP P1, §1). Pure.
///
/// The turn path has no id that reaches the speech service (KK's turns live in the conversation
/// store, `TurnRecorder` is instrumentation only), so the Direct-mode loop opens one of these
/// around each reply through `HUDAnswerCard.beginTurn()` / `endTurn()`, and the speech service
/// hands it what it says:
///
/// - **a streamed sentence** (`append`), as each one plays, while the reply is still being
///   written;
/// - **the final reply** (`finish(reply:)`), once it is known: when the whole reply is spoken in
///   one utterance, or when the streamed reply's text is final.
///
/// The text only ever grows, so pages the wearer has seen keep their words (`HUDAnswerPager` is
/// stable on prefixes). Once the reply is final, later sentences of the same turn are already in
/// it and are ignored.
struct HUDAnswerTurn: Equatable {
    /// Streamed sentences in the order they were spoken.
    private(set) var sentences: [String] = []
    /// The whole answer once the reply is final; nil while it is still streaming.
    private(set) var finalText: String?

    var isFinished: Bool { finalText != nil }
    var isEmpty: Bool { text.isEmpty }

    /// What the card shows.
    var text: String { finalText ?? sentences.joined(separator: " ") }

    mutating func append(_ sentence: String) {
        guard !isFinished else { return }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sentences.append(trimmed)
    }

    /// The reply is final. Text already spoken stays where it is; what the reply adds after it is
    /// appended. When the sentences said so far run on into the reply (the usual case), the card
    /// is what was said followed by the rest of the reply. When the reply is not a continuation of
    /// any of them (a preamble before a tool ran, a reply that replaced what was streamed), what
    /// was said stays and the reply follows it in full, as it is heard.
    mutating func finish(reply: String) {
        guard !isFinished else { return }
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentences.isEmpty else {
            finalText = reply
            return
        }
        let said = sentences.joined(separator: " ")
        // The longest run of the last sentences that the reply continues — earlier ones were said
        // before a tool ran and are not part of this reply.
        for start in sentences.indices {
            let reconciliation = StreamSpeechGate.reconcile(reply: reply, spoken: Array(sentences[start...]))
            if reconciliation.spokenIsPartOfReply {
                finalText = Self.join(said, reconciliation.remainder)
                return
            }
        }
        finalText = Self.join(said, reply)
    }

    /// The turn ended before a final reply was known (an error, a barge-in): the card is what
    /// was said.
    mutating func seal() {
        guard !isFinished else { return }
        finalText = text
    }

    private static func join(_ head: String, _ tail: String) -> String {
        tail.isEmpty ? head : head + " " + tail
    }
}

import Foundation

/// One turn of a live session, as **this device** saw it.
///
/// Plan FF P1/PR5. The live backends keep the conversation on the far side of a socket; when that
/// socket cannot be resumed, the only record left is the one the phone made from the transcription
/// events it was already receiving. This is that record's unit.
struct LiveTurnRecord: Equatable {

    enum Speaker: String, Equatable, CaseIterable {
        case wearer
        case assistant
    }

    let speaker: Speaker
    let text: String
    /// True when this turn never finished — the connection dropped, or the wearer spoke over it,
    /// while it was still being produced.
    ///
    /// Load-bearing rather than decorative: an answer cut off by the loss must never be handed back
    /// to a new session as though it had been delivered. The wearer may have heard three words of
    /// it, or none.
    let wasInterrupted: Bool

    init(speaker: Speaker, text: String, wasInterrupted: Bool = false) {
        self.speaker = speaker
        self.text = text
        self.wasInterrupted = wasInterrupted
    }
}

/// Plan FF P1/PR5 — the bounded context block a live session is restarted with when the server
/// would not, or could not, resume the old one.
///
/// # Why this exists
///
/// Gemini Live's resumption handle is the good path: the server still holds the conversation and
/// hands it back. It is not always available. The handle expires, a deliberate teardown drops it,
/// and a setup that goes out carrying one and does not come up has to drop it rather than loop the
/// whole retry ladder on a handle the server will not take. In every one of those cases the wearer
/// experiences the same thing — the assistant comes back having forgotten the last two minutes —
/// and a context-dependent follow-up ("and the other one?") becomes unanswerable.
///
/// So the phone rebuilds a small handover from its own record and puts it in front of the new
/// session as context. Three rules make that safe rather than merely helpful:
///
/// * **Bounded.** ``maxTurns`` turns, each clipped to ``maxCharactersPerTurn``. This is a locally
///   held copy of someone's speech; it is kept small and in memory, and it is stated here rather
///   than being an implementation detail of a ring buffer somewhere.
/// * **Never a replayed action.** A tool call that was in flight when the socket dropped is named
///   and marked *outcome unknown*, never re-issued. The journal knows which operations can have
///   left something behind (`ToolEffect.hasSideEffect`); those are exactly the ones a second
///   attempt could duplicate — a message sent twice, a light switched twice.
/// * **Never a completed answer.** An interrupted turn is marked interrupted in the block, in the
///   same words in both directions, so the model cannot refer back to an answer the wearer never
///   heard as if it had been given.
///
/// Pure: no store, no clock, no I/O. The recording half is ``LiveConversationRecorder``.
enum LiveContextHandover {

    /// How many turns of the local record go into a handover.
    ///
    /// Six turns is roughly the last three exchanges — enough that "and the other one?" has a
    /// referent, short enough that the block stays a paragraph rather than a transcript. It is a
    /// proposal until a wearer has used it, like the rest of this plan's numbers.
    static let maxTurns = 6

    /// How much of one turn is carried. A clipped turn says so, because a truncated sentence read
    /// back as complete is its own small lie.
    static let maxCharactersPerTurn = 300

    /// The marker the block opens with. Stable so it can be asserted, and so a reader of a captured
    /// instruction can tell locally rebuilt context from context the server restored.
    static let blockHeading = "RECOVERED CONVERSATION CONTEXT:"

    /// Build the handover block, or `nil` when there is nothing to hand over.
    ///
    /// `nil` is not a failure: a session that dropped before the wearer said anything has no thread
    /// to lose, and an empty block would only tell the model something untrue about how much it is
    /// expected to remember.
    ///
    /// - Parameters:
    ///   - turns: the local record, oldest → newest. Only the last `limit` are used.
    ///   - interruptedOperations: names of side-effecting tool operations that were in flight when
    ///     the connection dropped and whose outcome nobody can vouch for. Names only — no
    ///     arguments, no results, and never a call.
    ///   - limit: how many turns to carry.
    static func build(turns: [LiveTurnRecord],
                      interruptedOperations: [String] = [],
                      limit: Int = maxTurns) -> String? {
        let kept = carriedTurns(turns, limit: limit)
        guard !kept.isEmpty || !interruptedOperations.isEmpty else { return nil }

        var block = blockHeading + "\n" + preamble
        for turn in kept {
            block += "\n" + line(for: turn)
        }
        if let note = interruptedOperationsNote(interruptedOperations) {
            block += "\n" + note
        }
        block += "\n" + closingRule
        return block
    }

    /// The turns a handover carries: the newest `limit`, in order, empties dropped, each clipped.
    static func carriedTurns(_ turns: [LiveTurnRecord], limit: Int = maxTurns) -> [LiveTurnRecord] {
        let nonEmpty = turns.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let window = limit <= 0 ? [] : Array(nonEmpty.suffix(limit))
        return window.map { turn in
            LiveTurnRecord(speaker: turn.speaker,
                           text: clip(turn.text),
                           wasInterrupted: turn.wasInterrupted)
        }
    }

    /// How many turns a given record would contribute. The number the recovery assessment reports
    /// as `rebuilt(turns:)`, so the two cannot disagree.
    static func carriedTurnCount(_ turns: [LiveTurnRecord], limit: Int = maxTurns) -> Int {
        carriedTurns(turns, limit: limit).count
    }

    // MARK: - The words

    private static let preamble = """
        The live connection dropped and the previous session could not be restored, so you do not \
        have the earlier conversation. What follows is this device's own short record of the last \
        few turns, rebuilt locally so the wearer does not have to start again. Use it only to \
        understand what was being talked about.
        """

    private static let closingRule = """
        Do not repeat any answer above, do not run any action again on the strength of it, and do \
        not claim to remember anything beyond it. If the wearer refers to something that is not \
        here, say you lost the thread and ask them to say it again.
        """

    static func line(for turn: LiveTurnRecord) -> String {
        let quoted = "\"\(turn.text)\""
        switch (turn.speaker, turn.wasInterrupted) {
        case (.wearer, false):
            return "- They said: \(quoted)"
        case (.wearer, true):
            return "- They started saying: \(quoted) — they were cut off, so this may be incomplete."
        case (.assistant, false):
            return "- You answered: \(quoted)"
        case (.assistant, true):
            return "- You were answering: \(quoted) — the connection dropped before you finished. "
                + "They may have heard none of it. Do not treat this answer as delivered."
        }
    }

    /// The line about actions whose fate is unknown, or `nil` when there were none.
    ///
    /// Two things it deliberately does not do: name arguments, and suggest a retry. The journal's
    /// own retry advice for an unresolved side-effecting operation is "check what actually happened
    /// before running it again", and that check is a person's, not the model's.
    static func interruptedOperationsNote(_ names: [String]) -> String? {
        let unique = orderedUnique(names.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return nil }
        let list = unique.map { "'\($0)'" }.joined(separator: ", ")
        let subject = unique.count == 1 ? "An action was" : "Actions were"
        let pronoun = unique.count == 1 ? "it" : "them"
        return "- \(subject) already running when the connection dropped and the outcome is "
            + "unknown: \(list). Do NOT run \(pronoun) again. If it matters, tell the wearer the "
            + "outcome is unknown and let them decide."
    }

    // MARK: - Reading the journal

    /// The side-effecting operations the journal still cannot account for — the ones a replay could
    /// duplicate.
    ///
    /// Two filters, both load-bearing. **Read-only tools are excluded**: running a lookup twice
    /// changes nothing, and listing it would bury the one line that matters under noise. And the
    /// journal is **bounded to this session** by `since`, because it is durable and deliberately
    /// long-lived — it carries rows recovered from a process that died days ago, and a handover
    /// that named one of those would tell the model an unrelated old message might have gone out in
    /// the conversation it is resuming.
    ///
    /// `since` of `nil` means no bound, which is only right for a caller that has no session to
    /// bound by.
    @MainActor
    static func interruptedSideEffectingOperations(in journal: any OperationJournal,
                                                   since: Date? = nil) -> [String] {
        orderedUnique(journal.unresolvedOperations
            .filter { $0.effect.hasSideEffect }
            .filter { record in since.map { record.startedAt >= $0 } ?? true }
            .map(\.toolName))
    }

    // MARK: - Private

    private static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharactersPerTurn else { return trimmed }
        return String(trimmed.prefix(maxCharactersPerTurn)) + "… (cut short here)"
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

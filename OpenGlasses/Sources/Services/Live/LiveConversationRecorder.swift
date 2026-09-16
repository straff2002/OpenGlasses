import Foundation

/// Plan FF P1/PR5 — the phone's own short record of a live session's turns.
///
/// # Why there was nothing to read
///
/// The audit this came out of expected to find live turns somewhere in `ConversationStore` or
/// `LLMService.conversationHistory`. They are not there, on either realtime backend. Both session
/// managers keep exactly two strings — `userTranscript` and `aiTranscript` — each cleared at the
/// next turn boundary, and the only readers are two transcript views. A live conversation is
/// therefore *entirely* server-side: when the server will not resume it, there is nothing on this
/// device to rebuild it from.
///
/// So this records the minimum a handover needs, and nothing else.
///
/// # What it keeps, and for how long
///
/// * **In memory only.** Never written to disk, never in a thread, never in the conversation store,
///   never in a log — `PrivacyLog` records counts, not speech, and so does everything here.
/// * **Bounded twice.** ``capacity`` turns, each clipped to
///   ``LiveContextHandover/maxCharactersPerTurn`` when it is carried into a handover.
/// * **The session's lifetime.** ``reset()`` is called when a session starts and when it stops, so
///   ending a session is the same act as forgetting it. Nothing survives into the next one.
///
/// That is a deliberately narrow privacy posture: enough to answer "and the other one?" after a
/// reconnect, and not a transcript feature by the back door.
@MainActor
final class LiveConversationRecorder {

    /// How many committed turns are kept. Twice the handover window, so the last
    /// ``LiveContextHandover/maxTurns`` are always available even when the newest turn is still
    /// in flight.
    static let capacity = 12

    private(set) var turns: [LiveTurnRecord] = []

    /// The turn currently being produced, if any. Committed at a turn boundary, at an interruption,
    /// or when the other speaker starts.
    private var wearerInFlight = ""
    private var assistantInFlight = ""

    var hasRecordedTurns: Bool { !turns.isEmpty }

    /// Whether an answer is being produced right now — the case where a connection loss interrupts
    /// something the wearer was mid-way through hearing.
    var hasAnswerInFlight: Bool { !assistantInFlight.isEmpty }

    // MARK: - Recording

    /// The wearer's current utterance, as transcribed so far.
    ///
    /// Takes the whole accumulated string rather than the chunk, so this shares the session
    /// manager's own script-aware joining instead of re-implementing it and drifting from it.
    func setWearerTurn(_ text: String) {
        // The wearer speaking while the model is answering is a barge-in: the answer stopped where
        // it stopped, and the wearer heard only part of it.
        commitAssistantInFlight(interrupted: true)
        wearerInFlight = text
    }

    /// The assistant's current answer, as transcribed so far.
    func setAssistantTurn(_ text: String) {
        commitWearerInFlight(interrupted: false)
        assistantInFlight = text
    }

    /// A turn finished normally.
    func completeTurn() {
        commitWearerInFlight(interrupted: false)
        commitAssistantInFlight(interrupted: false)
    }

    /// Something cut the turn short — the socket dropped, or the model was interrupted.
    ///
    /// The wearer's own utterance is committed unmarked: what they said, they said. The answer is
    /// committed **marked**, because whether they heard it is exactly what nobody knows.
    func noteInterruption() {
        commitWearerInFlight(interrupted: false)
        commitAssistantInFlight(interrupted: true)
    }

    /// Forget everything. Called when a session starts and when it stops.
    func reset() {
        turns.removeAll()
        wearerInFlight = ""
        assistantInFlight = ""
    }

    // MARK: - Reading

    /// The newest `limit` turns, oldest → newest, including anything still in flight (committed
    /// as interrupted, because reading the record mid-turn is exactly the reconnect case).
    func recentTurns(_ limit: Int = LiveContextHandover.maxTurns) -> [LiveTurnRecord] {
        var all = turns
        if !wearerInFlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            all.append(LiveTurnRecord(speaker: .wearer, text: wearerInFlight, wasInterrupted: false))
        }
        if !assistantInFlight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            all.append(LiveTurnRecord(speaker: .assistant, text: assistantInFlight,
                                      wasInterrupted: true))
        }
        return limit <= 0 ? [] : Array(all.suffix(limit))
    }

    // MARK: - Private

    private func commitWearerInFlight(interrupted: Bool) {
        let text = wearerInFlight
        wearerInFlight = ""
        append(speaker: .wearer, text: text, interrupted: interrupted)
    }

    private func commitAssistantInFlight(interrupted: Bool) {
        let text = assistantInFlight
        assistantInFlight = ""
        append(speaker: .assistant, text: text, interrupted: interrupted)
    }

    private func append(speaker: LiveTurnRecord.Speaker, text: String, interrupted: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(LiveTurnRecord(speaker: speaker, text: trimmed, wasInterrupted: interrupted))
        if turns.count > Self.capacity {
            turns.removeFirst(turns.count - Self.capacity)
        }
    }
}

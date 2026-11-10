import Foundation

/// What a Direct turn needs from the speech service to stream a reply (Plan HZ P1).
/// `TextToSpeechService` is the real one; the turn-level tests hand in a recorder.
@MainActor
protocol StreamedReplySpeaking: AnyObject {
    /// Start a reply spoken a sentence at a time; `isCurrent` is checked before each sentence.
    func beginStreamedReply(isCurrent: @escaping @MainActor () -> Bool) -> StreamedReplyQueue
    /// Today's path: say the whole text in one utterance.
    func speakWholeReply(_ text: String) async
}

/// One Direct turn's streamed reply (Plan HZ P1): the turn's `onToken`, `onStreamReset` and
/// `speak:` closures, joined up.
///
/// - `ingest(_:)` is `onToken`. Chunks go through the `StreamSpeechGate`; each sentence it
///   releases goes to a `StreamedReplyQueue`, opened on the first one. Until something is released
///   nothing has changed, so a reply the gate holds from the start is spoken exactly as today.
/// - `streamDidReset()` is `onStreamReset`: the tool loop is starting another iteration. The
///   iteration's last complete sentence may still be said, and whatever this iteration said is
///   reported through `onPreamble` so the transcript shows it as its own line — what was heard is
///   what is shown (open question 1, recommended answer).
/// - `finish(reply:)` is `speak:`. When nothing was streamed it is `speak(response)`, unchanged.
///   Otherwise it reconciles the final reply with what was already said and queues only the rest.
///
/// A barge-in or "stop" reaches the queue through `TextToSpeechService.stopSpeaking`, and from
/// then on this reply says nothing more — not the rest of the stream, not the remainder.
@MainActor
final class DirectReplySpeechStream {

    private weak var speaker: (any StreamedReplySpeaking)?
    private let gate: StreamSpeechGate
    /// Plan KZ §6: citation markup is taken out before the sentence splitter sees the text, and
    /// half a link is held until it is whole, so no address is spoken part-way.
    private var citations = CitationMarkupStripper.Stream()
    private let isCurrent: @MainActor () -> Bool
    /// The reply's queue, opened by the first released sentence.
    private(set) var queue: StreamedReplyQueue?
    /// Where this iteration's sentences start in the queue.
    private var iterationStart = 0
    /// The sentences this iteration handed to the queue.
    private var iterationSentences: [String] = []
    /// Lines said before a reset (tool preambles), in order.
    private(set) var preambles: [String] = []

    /// Called once, when the first sentence starts playing — the turn starts its stop listener.
    var onSpeechBegan: (() -> Void)?
    /// Called with each preamble line, for the transcript.
    var onPreamble: ((String) -> Void)?
    /// The stop listener was started for this reply and is owed a stop.
    var holdsStopListener = false
    /// Plan LA: every tool call of the turn so far, as the quiet-ending judge reads them. Read at
    /// each stream reset; the calls since the previous reset are the round the gate is told about.
    private let turnCalls: @MainActor () -> [QuietTurnCall]
    /// How many of `turnCalls` an earlier reset already accounted for.
    private var accountedCalls = 0

    init(speaker: any StreamedReplySpeaking, rules: StreamSpeechGate.Rules = .default,
         isCurrent: @escaping @MainActor () -> Bool = { true },
         turnCalls: @escaping @MainActor () -> [QuietTurnCall] = { [] }) {
        self.speaker = speaker
        self.gate = StreamSpeechGate(rules: rules)
        self.isCurrent = isCurrent
        self.turnCalls = turnCalls
    }

    /// Plan LA §4: the final iteration is being held whole for the quiet-ending verdict.
    var isHoldingForVerdict: Bool { gate.holdReason == .quietCandidate }

    /// Streaming ran for this turn: at least one sentence went to the queue.
    var didStream: Bool { queue != nil }

    /// The wearer, or a conversation reset, cut the reply short. A reply superseded by another
    /// utterance (a notice) is not stopped: the rest of it is still owed and said at the end.
    var wasStopped: Bool {
        guard let interruption = queue?.interruption else { return false }
        return interruption != .newUtterance
    }

    // MARK: - The turn's closures

    /// `onToken`.
    func ingest(_ chunk: String) {
        let clean = citations.ingest(chunk)
        let sentences = clean.isEmpty ? [] : gate.ingest(clean)
        guard !Task.isCancelled, !wasStopped, isCurrent() else { return }
        enqueue(sentences)
    }

    /// `onStreamReset`.
    func streamDidReset() {
        let held = citations.flush()
        let calls = turnCalls()
        let round = Array(calls.dropFirst(accountedCalls))
        accountedCalls = calls.count
        let tail = (held.isEmpty ? [] : gate.ingest(held)) + gate.endIteration(roundCalls: round)
        if !Task.isCancelled, !wasStopped, isCurrent() { enqueue(tail) }
        let said = spokenThisIteration
        if !said.isEmpty {
            let line = said.joined(separator: " ")
            preambles.append(line)
            onPreamble?(line)
        }
        iterationSentences = []
        iterationStart = queue?.sentenceCount ?? 0
    }

    /// `speak:` — the reply is final.
    func finish(reply raw: String) async {
        guard let speaker else { return }
        // Reconciled against what can be spoken: the reply with its citation markup taken out,
        // exactly as the streamed sentences had it.
        let reply = CitationMarkupStripper.strip(raw)
        guard let queue else {
            // Nothing was streamed: today's path, byte for byte.
            await speaker.speakWholeReply(reply)
            return
        }
        guard !wasStopped else { return }
        let said = spokenThisIteration
        let reconciliation = StreamSpeechGate.reconcile(reply: reply, spoken: said)
        if !reconciliation.spokenIsPartOfReply {
            // The reply that came back is not the text that was streamed (a yield, a wrap-up):
            // what was said stands as its own line, and the reply is said in full after it.
            let line = said.joined(separator: " ")
            preambles.append(line)
            onPreamble?(line)
        }
        let remainder = reconciliation.remainder
        PrivacyLog.tts(.streamedReplyReconciled, characters: remainder.count,
                       count: said.count,
                       detail: PrivacyToken(reconciliation.spokenIsPartOfReply ? "continued" : "replaced"))
        if !queue.isCancelled {
            if !remainder.isEmpty { queue.enqueue(remainder) }
            await queue.finish()
        }
        // Another utterance took the floor mid-reply (before now, or while the rest played): what
        // was not heard is still owed, and is said whole once it is done.
        if queue.isCancelled, queue.interruption == .newUtterance {
            await queue.finish()
            let heard = queue.heardSentences(from: iterationStart)
            let rest = StreamSpeechGate.reconcile(reply: reply, spoken: heard).remainder
            if !rest.isEmpty { await speaker.speakWholeReply(rest) }
        }
    }

    /// Plan LA: the turn ends with the done tone. Nothing more of the reply is said; anything a
    /// queue already holds (a sentence released before the last tool round) plays out, so the tone
    /// that follows does not cut it off.
    func finishQuietly() async {
        guard let queue, !wasStopped, !queue.isCancelled else { return }
        await queue.finish()
    }

    // MARK: - Internals

    /// What this iteration actually said or will say: everything queued while the reply holds the
    /// floor, only what was heard once it lost it.
    private var spokenThisIteration: [String] {
        guard let queue else { return [] }
        return queue.isCancelled ? queue.heardSentences(from: iterationStart) : iterationSentences
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty, let speaker else { return }
        if queue == nil {
            let opened = speaker.beginStreamedReply(isCurrent: isCurrent)
            opened.onPlaybackBegan = { [weak self] in
                guard let self else { return }
                self.holdsStopListener = true
                self.onSpeechBegan?()
            }
            queue = opened
            // Plan CU: the reply reaches the engine now, long before generation ends — the
            // negative `ttsLeadIn` this plan is measured by.
            TurnRecorder.handOffToSpeech()
        }
        guard let queue, !queue.isCancelled else { return }
        for sentence in sentences {
            queue.enqueue(sentence)
            iterationSentences.append(sentence)
        }
    }
}

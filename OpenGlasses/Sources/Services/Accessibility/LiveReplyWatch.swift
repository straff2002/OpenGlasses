import Foundation

/// Watches a live session's answer as its transcript arrives and says what to do when a sentence
/// trips the reply check (Plan NA §5). Pure: the session manager feeds it and obeys the effects,
/// so every decision is tested headlessly although the manager cannot be built in a test.
///
/// The live providers deliver audio and transcript separately, and the transcript trails the
/// audio's *arrival*, not its playback: when a sentence's words are known, its audio is often
/// still queued. So a trip stops at once (decision 5) — `stopPlayback` drops what is queued — and
/// on OpenAI Realtime cancels the response, which truncates the server's item to what was played.
/// Gemini has no cancel: `muteUntilTurnEnd` latches, and the manager drops its audio and
/// transcript for the rest of the response. The correction is said in the app's own voice, and
/// the model is told at the turn's end (decision 7), once.
///
/// A sentence that names a hazard is not stopped: it is already playing, and the hazard is the
/// part the wearer needs. Its correction is said when the turn ends.
struct LiveReplyWatch {

    enum Provider: String, Sendable {
        /// OpenAI Realtime and the other JSON providers: `cancelResponse` truncates the item.
        case json
        /// Gemini Live: no cancel; the audio keeps arriving and is dropped.
        case gemini
    }

    enum Effect: Equatable, Sendable {
        /// Drop the audio still queued.
        case stopPlayback
        /// Cancel the response on the server (JSON providers only).
        case cancelResponse
        /// Drop the rest of this response's audio and transcript until the turn ends.
        case muteUntilTurnEnd
        /// Say the correction in the app's own voice.
        case speakLine(BlindReplyLine)
        /// Tell the model, at the turn boundary.
        case noteForModel(BlindReplyLine)
        /// The answer was cut short: the record and the answer card must not present it as
        /// delivered.
        case markInterrupted
        /// The turn's screened sentences, for the tally and the log.
        case record([BlindReplyScreen.Screened])
    }

    let provider: Provider
    let scope: BlindReplyScreen.Scope
    let appLanguageIsEnglish: Bool

    private var splitter = SentenceStreamSplitter()
    private var replyScreen: BlindReplyScreen?
    /// The transcript the splitter has been handed.
    private var fed = ""
    /// The rest of this response is dropped.
    private(set) var isMuted = false
    /// A line owed at the turn's end (a hazard sentence that tripped and was let play).
    private var owedLine: BlindReplyLine?
    /// What the model is told at the turn's end.
    private var owedNote: BlindReplyLine?

    init(provider: Provider, scope: BlindReplyScreen.Scope, appLanguageIsEnglish: Bool = true) {
        self.provider = provider
        self.scope = scope
        self.appLanguageIsEnglish = appLanguageIsEnglish
    }

    /// Whether this watch checks anything at all.
    var isWatching: Bool { !scope.isOff }

    // MARK: - In

    /// The answer's transcript so far (joined the way the manager joins it). `question` is the
    /// wearer's transcript as it stands: a JSON provider may deliver it after the answer started,
    /// so the question-aware check is best effort there.
    mutating func outputTranscript(_ transcript: String, question: String?,
                                   evidence: ReadingEvidence?) -> [Effect] {
        guard isWatching, !isMuted else { return [] }
        let new: String
        var effects: [Effect] = []
        if transcript.hasPrefix(fed) {
            new = String(transcript.dropFirst(fed.count))
        } else {
            // The manager started a new answer under us (its transcript was reset): start over,
            // keeping the record of what was checked and anything still owed at the boundary.
            if let screened = replyScreen?.screened, !screened.isEmpty { effects.append(.record(screened)) }
            splitter.reset()
            replyScreen = nil
            new = transcript
        }
        fed = transcript
        guard !new.isEmpty else { return effects }
        return effects + screen(splitter.ingest(new), question: question, evidence: evidence)
    }

    /// The turn ended normally: the last sentence is checked, then the turn's owed line and note.
    mutating func turnComplete(question: String?, evidence: ReadingEvidence?) -> [Effect] {
        guard isWatching else { return [] }
        var effects = isMuted ? [] : screen(splitter.flush(), question: question, evidence: evidence)
        effects += boundary()
        return effects
    }

    /// The wearer spoke over the answer, or the provider cut it: what was not heard is not
    /// checked, and the turn's owed line and note are still given.
    mutating func interrupted() -> [Effect] {
        guard isWatching else { return [] }
        return boundary()
    }

    // MARK: - Internals

    private mutating func screen(_ sentences: [String], question: String?,
                                 evidence: ReadingEvidence?) -> [Effect] {
        guard !sentences.isEmpty else { return [] }
        if replyScreen == nil {
            replyScreen = BlindReplyScreen(surface: .live, scope: scope, question: question,
                                           appLanguageIsEnglish: appLanguageIsEnglish)
        } else if replyScreen?.question == nil {
            replyScreen?.question = question
        }
        var effects: [Effect] = []
        for sentence in sentences {
            guard var current = replyScreen else { break }
            let item = current.screen(sentence, evidence: evidence)
            replyScreen = current
            switch item.action {
            case .stopAndCorrect(let line):
                effects += stopEffects() + [.speakLine(line)]
                owedNote = owedNote ?? line
            case .drop:
                // A second trip after a hazard sentence's correction is owed: stopped, and the
                // owed line covers it.
                effects += stopEffects()
            case .speakThenCorrect(let line):
                owedLine = owedLine ?? line
                owedNote = owedNote ?? line
            case .replace, .count:
                break
            }
            if isMuted { break }
        }
        return effects
    }

    private mutating func stopEffects() -> [Effect] {
        isMuted = true
        var effects: [Effect] = [.stopPlayback]
        if provider == .json { effects.append(.cancelResponse) }
        return effects + [.muteUntilTurnEnd, .markInterrupted]
    }

    /// The turn's end: the owed line, the note for the model, the turn's record, and a clean
    /// slate for the next answer.
    private mutating func boundary() -> [Effect] {
        var effects: [Effect] = []
        if let owedLine { effects.append(.speakLine(owedLine)) }
        if let owedNote { effects.append(.noteForModel(owedNote)) }
        if let screened = replyScreen?.screened, !screened.isEmpty { effects.append(.record(screened)) }
        splitter.reset()
        replyScreen = nil
        fed = ""
        isMuted = false
        owedLine = nil
        owedNote = nil
        return effects
    }
}

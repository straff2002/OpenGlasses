import Foundation

/// The app side of the reply check for Direct turns (Plan NA P1): which turns are checked, the
/// streamed reply told how to check its sentences, and the final reply screened by the same
/// function before anything accepts, shows or speaks it. Every decision lives in
/// `BlindReplyCheck`, `BlindReplyGuard` and `BlindReplyScreen`; this file only reads settings and
/// calls them.
extension AppState {

    /// Decision 8: the phrase tables while Blind Assistant is selected; the reading-number check
    /// on any turn with reading evidence; never the interpreter; nothing with the kill switch off.
    var directReplyCheckScope: BlindReplyScreen.Scope {
        .forTurn(activeModeId: Config.activeLiveAIModeId, enabled: Config.blindReplyCheckEnabled)
    }

    /// A Direct turn is starting: its reading evidence starts empty, and a streamed reply checks
    /// each sentence before it is queued.
    func beginDirectReplyCheck(question: String, stream: DirectReplySpeechStream?) {
        ReadingEvidenceBoard.shared.clear()
        let scope = directReplyCheckScope
        guard !scope.isOff, let stream else { return }
        stream.checkReplies(
            with: BlindReplyScreen(surface: .direct, scope: scope, question: question,
                                   appLanguageIsEnglish: BlindReplyScreen.appLanguageIsEnglish),
            evidence: { ReadingEvidenceBoard.shared.current })
    }

    /// The final reply, screened sentence by sentence as the stream screened it. The transcript,
    /// the answer card, the whole-reply speech and the model's history all get what this returns,
    /// so what was heard is what is shown and what the model remembers saying.
    func screenDirectReply(_ reply: String, question: String) -> String {
        let scope = directReplyCheckScope
        guard !scope.isOff else { return reply }
        let whole = BlindReplyScreen.screenWhole(
            reply, surface: .direct, scope: scope, question: question,
            evidence: ReadingEvidenceBoard.shared.current,
            appLanguageIsEnglish: BlindReplyScreen.appLanguageIsEnglish)
        BlindReplyCheckRecorder.record(whole.screened, surface: .direct)
        guard whole.changed else { return reply }
        llmService.applyReplyCheckReplacements(whole.replacements)
        return whole.text
    }

    /// The turn is over: its reading evidence goes with it.
    func endDirectReplyCheck() {
        ReadingEvidenceBoard.shared.clear()
    }
}

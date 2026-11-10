import Foundation
import UIKit

/// Plan LA — Quiet After Actions, the app's side: what the judge is told about a Direct turn, and
/// what a quiet ending does (the tone, "Done" for VoiceOver, the wrist tap, the replay window).
/// The rules themselves are `QuietTurnJudge`'s, and pure.
extension AppState {

    /// The setting as the turn reads it: on, and not in Simple Mode (rule 1).
    var quietAfterActionsActive: Bool {
        Config.quietAfterActionsEnabled && !Config.simpleModeEnabled
    }

    /// Every tool call of the turn so far, as the judge reads them. `lookup_tools` is the model
    /// fetching a definition, not a lookup the wearer asked for, so it is left out.
    func quietTurnCalls() -> [QuietTurnCall] {
        llmService.turnToolLedger.quietCalls().filter { $0.tool != ToolLookupTool.toolName }
    }

    /// The verdict for a spoken Direct turn whose reply is final. Nil — no verdict, today's path —
    /// when the setting is off, so nothing is traced or logged for a wearer who never turned it on.
    func judgeQuietEnding(utterance: String, reply: String, hasFollowUps: Bool) -> QuietTurnVerdict? {
        guard Config.quietAfterActionsEnabled else { return nil }
        let calls = quietTurnCalls()
        let verdict = QuietTurnJudge.judge(QuietTurnInput(
            enabled: Config.quietAfterActionsEnabled,
            simpleMode: Config.simpleModeEnabled,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            origin: .spokenDirect,
            languageCode: Self.quietTurnLanguage(preference: Config.speechRecognitionLocale,
                                                 preferred: Locale.preferredLanguages),
            utterance: utterance,
            calls: calls,
            reply: reply,
            hasFollowUps: hasFollowUps))
        TurnRecorder.noteQuietVerdict(verdict.traceToken)
        let detail: String
        switch verdict {
        case .quiet: detail = "quiet"
        case .speak(let reason): detail = reason.rawValue
        }
        PrivacyLog.app(.quietTurnJudged, detail: PrivacyToken(detail), count: calls.count)
        return verdict
    }

    /// The language the wearer spoke in: the pinned recognition locale, or the device's first
    /// preferred language for "auto". Pure.
    nonisolated static func quietTurnLanguage(preference: String, preferred: [String]) -> String {
        let chosen = preference == "auto" ? (preferred.first ?? "en") : preference
        return UtteranceQuestionCue.base(chosen)
    }

    /// A quiet ending: the done tone, "Done" after it for a VoiceOver user who wants the words
    /// (decision 5), the wrist tap, and the reply kept for "what was that?" (decision 7).
    func playQuietEnding(reply: String) async {
        // The thinking sound stops as it would for a spoken reply, so the tone is heard alone.
        speechService.stopThinkingSound()
        await speechService.playQuietDoneTone()
        if QuietDoneCue.speaksMeaning(voiceOverRunning: UIAccessibility.isVoiceOverRunning,
                                      spokenCuesOn: Config.blindAssistantSpokenCues) {
            await speechService.speak(QuietDoneCue.spokenMeaning, source: .acknowledgement)
        }
        WatchConnectivityManager.shared.sendQuietDone()
        quietReplay.noteQuietTurn(reply: reply, at: Date())
    }

    /// "What was that?" inside the window: the reply that was not said, with no model call. Nil
    /// when the utterance does not ask, or the window has closed.
    func quietReplayReply(for utterance: String) -> String? {
        quietReplay.replay(for: utterance, at: Date())
    }
}

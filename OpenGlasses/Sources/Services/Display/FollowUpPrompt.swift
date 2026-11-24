import Foundation

/// Whether a Direct-mode prompt asks the model for suggested follow-ups, and the clause that asks
/// (Plan KP §4, P2).
///
/// The model writes the follow-ups in the same reply, as a tagged tail (`FollowUpTail`), only when
/// something shows them: a glasses display with the HUD on. Decision 5 sets the default: **on for
/// the Display**, read by `wanted(surface:onDisplay:)`:
/// - a glasses display that can show answers (the HUD on, the active backend has a display) reads
///   `Config.followUpsOnDisplayEnabled` (default on);
/// - nothing showing answers: no clause, whatever the setting says.
///
/// While another app has the Display (§8) the clause stays: the card is held and comes back.
///
/// Direct mode only. The clause is added to the full cloud prompt (`LLMService.buildSystemPrompt`
/// with `offersFollowUps`), not to the short prompts of on-device models (a 2B model's window and
/// memory are already tight, and it has its own lean prompt) or to the one-line lean cloud
/// prompt, and never to the live modes (Gemini Live, OpenAI Realtime, Qwen, Doubao): their turns
/// reach the answer card since Plan LC §5, but as the transcript of what the model said aloud, so a
/// tail asked of them would be spoken — a live card carries no follow-ups.
///
/// Allowed under HIPAA mode: the follow-ups never leave the reply. The tail is taken off before
/// the transcript, history, memory or speech see it, and its questions go only to the card.
enum FollowUpPrompt {

    /// What would show an answer's follow-ups now.
    enum Surface: Equatable {
        /// A glasses display (Meta Ray-Ban Display or Even G2) with the HUD on.
        case display
        /// Nothing shows answers.
        case none
    }

    /// The clause. Short on purpose: it rides on every turn while a display is up.
    static let clause = """
        FOLLOW-UPS: The user's display shows buttons for next questions under your answer. After \
        your answer, on a line of its own, write \(FollowUpTail.openTag) then up to \
        \(FollowUpTail.maxFollowUps) short questions the user might ask next, each \
        \(FollowUpTail.maxWords) words or fewer, in the language of your answer, separated by |, \
        then \(FollowUpTail.closeTag). It is the very last thing in your reply, after any memory \
        tags. It is never spoken or shown as text, so never mention it. Example: \(FollowUpTail.openTag)How long does it take?|What does it cost?\(FollowUpTail.closeTag)
        """

    /// Pure: whether the clause is wanted for `surface` with this setting.
    static func wanted(surface: Surface, onDisplay: Bool) -> Bool {
        switch surface {
        case .display: return onDisplay
        case .none: return false
        }
    }

    /// The live surface. `AppState` points it at `GlassesDisplayService.answerSurface`; until then,
    /// and in tests that don't set it, nothing shows answers.
    @MainActor static var currentSurface: @MainActor () -> Surface = { .none }

    /// The clause for this turn's prompt, or nil.
    @MainActor static func clauseForPrompt() -> String? {
        wanted(surface: currentSurface(), onDisplay: Config.followUpsOnDisplayEnabled) ? clause : nil
    }
}

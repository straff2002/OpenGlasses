import Foundation

/// Where a hint goes on the lens (Plan MO §5a, "During a procedure").
///
/// A running procedure (or any HUD task) holds its step card on the lens, and an answer card is
/// never made over a task card (`GlassesDisplayService.acceptsAnswerCard`). A hint then goes over
/// the step card the way a notification does: a transient frame with no buttons, which the display
/// takes down after `HintLimits.overTaskFlashDuration` and replaces with the step card, as it was.
/// The step card stays the held screen the whole time, with its own selection handler, so a band
/// press or a spoken step word still means the step, and nothing the hint shows can advance,
/// answer or skip it.
///
/// | The lens holds | The hint |
/// |---|---|
/// | nothing, an answer card, the turn's card, a page cue | its card (`HintLensCardBuilder`) |
/// | a task card (a procedure's step) | a flash over the step card |
/// | a menu, an approval card, a page view, another app | nothing on the lens |
/// | a lens the wearer dismissed, for a hint they didn't ask for | nothing on the lens |
///
/// Pure.
enum HintLensPlacement: Equatable, Sendable {
    case card
    case overTask
    case none

    static func decide(acceptsAnswerCard: Bool, taskCardShowing: Bool, lensDismissed: Bool,
                       wearerLed: Bool) -> HintLensPlacement {
        if lensDismissed, !wearerLed { return .none }
        if acceptsAnswerCard { return .card }
        if taskCardShowing { return .overTask }
        return .none
    }

    /// What the flash over a step card says: the question in a few words (or the keyword) above
    /// the hint's line. No source line: the card's second page is the phone's, during a step.
    static func flash(for hint: LiveHint) -> (title: String?, body: String) {
        let title: String?
        if let question = hint.question {
            let glance = HintQuestionGlance.glance(question)
            title = glance.isEmpty ? nil : glance
        } else {
            title = hint.keyword
        }
        return (title, HintText.collapsingWhitespace(hint.line))
    }
}

import Foundation

/// What the wearer is told about Assistive Mode's Social mode (Plan HP P2 item 11). Pure, so the
/// copy is tested headless; the settings footer reads it.
///
/// Plan HS P1 item 2 removed the two refusal lines (managed phone, Field Assist edition) with the
/// refusals themselves. The refusals left (the wearer's own switch, the Accessibility tier) show
/// themselves in the switches, so there is no refusal copy and the Social mode switch is always
/// editable.
enum SocialModeCopy {

    /// Said wherever Social mode is offered or explained: what it describes, and that it does not
    /// guess at feelings (Plan HR P2 item 5 — the mode is observe-only).
    static var standingFooter: String {
        String(localized: "Social mode describes what you can see about the person in front of you: their expression, where they're looking and what they're doing. It doesn't guess how they feel.")
    }
}

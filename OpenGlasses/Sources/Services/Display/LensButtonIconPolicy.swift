import Foundation

/// Which lens buttons are sent with their icon: none, for now.
///
/// A label is never traded for an icon, and on Meta's simulated Display an icon costs the label:
/// - on the 1.0.1 preview a `.secondary` button with an icon drew as the icon alone, its label lost;
/// - on the 1.1.0 preview every button with an icon, `.primary` included, draws as the icon alone in
///   an 88 px circle (measured 2026-11-22, `SimulatedDisplayButtonRows`).
/// A bare glyph leaves the wearer guessing what the button does, so no lens button is sent with an
/// icon, whatever its style. Builders still give their items icons (the ready and What's new
/// buttons on the Today screen, a prepared card's primary button): the item keeps it, and only what
/// is sent to the Meta Display drops it. Icons on text lines (`HUDLine`: the clock, the calendar,
/// the weather) are not buttons and are unaffected.
///
/// This rests on what the simulator showed. Whether real glasses draw an icon and its label together
/// is not yet checked: the device pass checks it, and if they do this can be relaxed (by style, as
/// it once was) without touching its callers.
///
/// The on-phone preview walks the same component tree the lens is sent, so it follows this rule
/// without a copy of it.
enum LensButtonIconPolicy {
    /// The icon to send for a button of `style`: `.none`, whatever the style (see the type's note).
    static func icon(_ icon: HUDIcon, style: HUDButtonStyle) -> HUDIcon {
        switch style {
        case .primary, .secondary, .outline: return .none
        }
    }
}

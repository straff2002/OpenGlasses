import Foundation

/// Which lens buttons are sent with their icon.
///
/// Meta's simulated Display preview (DAT 1.0.1) draws a `.primary` button with an icon as icon and
/// label, but a `.secondary` button with an icon as the icon alone: its label is lost, and the
/// wearer is left guessing what a bare glyph does. So a button keeps its icon only when its style is
/// `.primary`; every other style is sent as its label with no icon. A label is never traded for an
/// icon. `.outline` has not been seen with an icon and is treated like `.secondary` until it has.
///
/// This rests on what the simulator showed. Whether real glasses draw it the same way is not yet
/// checked: a device pass is owed, and if the hardware keeps the labels this can be relaxed.
///
/// The on-phone preview walks the same component tree the lens is sent, so it follows this rule
/// without a copy of it.
enum LensButtonIconPolicy {
    /// The icon to send for a button of `style`: `icon` for a primary button, `.none` otherwise.
    static func icon(_ icon: HUDIcon, style: HUDButtonStyle) -> HUDIcon {
        switch style {
        case .primary: return icon
        case .secondary, .outline: return .none
        }
    }
}

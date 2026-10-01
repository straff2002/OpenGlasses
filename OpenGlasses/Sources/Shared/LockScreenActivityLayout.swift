import CoreGraphics

/// How the Lock Screen Live Activity lays out its action buttons — shared by the widget, which
/// draws it, and the app's tests, which hold it to the slot.
///
/// The system gives the Lock Screen presentation a hard height (`systemHeightLimit`) and clips
/// whatever is drawn past it. The activity used to draw a header, a status line and a 2 × 2 grid
/// of 44 pt capsules, and the second row of the grid was cut off by the Lock Screen on a phone.
/// It is one row of buttons now: up to four, each a glyph over a one-line caption, or a glyph
/// beside its label when there are only one or two and the width is there for it.
///
/// Disconnected, the Connect button takes the first of the four places rather than a row of its
/// own, which is what keeps the height the same in both states.
enum LockScreenActivityLayout {
    /// What the system allows the Lock Screen presentation, in points.
    static let systemHeightLimit: CGFloat = 160
    /// The most buttons the one row holds: four keeps a caption like "Safety Check" readable at
    /// the narrowest iPhone width (each button is then ~75 pt wide).
    static let maxButtons = 4
    /// Every button is at least a fingertip tall.
    static let minimumButtonHeight: CGFloat = 44

    // The view's own spacing, here so the height check below is the view's arithmetic.
    static let outerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 8
    static let buttonVerticalPadding: CGFloat = 6
    static let glyphCaptionSpacing: CGFloat = 2
    /// The header row is the power button's 44 pt target — the tallest thing in it.
    static let headerRowHeight: CGFloat = 44
    static let headerStatusSpacing: CGFloat = 2

    enum ButtonStyle: Equatable {
        /// Glyph beside the label, for one or two wide buttons.
        case glyphBesideLabel
        /// Glyph over a one-line caption, for three or four narrow ones.
        case glyphOverLabel
    }

    struct Plan: Equatable {
        /// How many of the quick actions are shown, in their order.
        let actionCount: Int
        /// Whether a Connect button leads the row.
        let showsConnect: Bool
        let style: ButtonStyle

        var buttonCount: Int { actionCount + (showsConnect ? 1 : 0) }
    }

    static func plan(availableActions: Int, isConnected: Bool) -> Plan {
        let places = isConnected ? maxButtons : maxButtons - 1
        let actions = min(max(0, availableActions), places)
        let total = actions + (isConnected ? 0 : 1)
        return Plan(actionCount: actions, showsConnect: !isConnected,
                    style: total <= 2 ? .glyphBesideLabel : .glyphOverLabel)
    }

    /// The height the presentation draws, given the rendered heights of its status line (0 when
    /// there is none), a button glyph and a caption line at the current text size.
    static func estimatedHeight(statusLine: CGFloat, glyph: CGFloat, caption: CGFloat,
                                style: ButtonStyle) -> CGFloat {
        let header = statusLine > 0
            ? headerRowHeight + headerStatusSpacing + statusLine
            : headerRowHeight
        let content = style == .glyphOverLabel
            ? glyph + glyphCaptionSpacing + caption
            : max(glyph, caption)
        let button = max(minimumButtonHeight, content + buttonVerticalPadding * 2)
        return outerPadding * 2 + header + sectionSpacing + button
    }
}

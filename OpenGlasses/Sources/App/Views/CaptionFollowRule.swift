import CoreGraphics

/// Whether the live captions follow the newest line (Plan KP §7, P5). Pure, so the rule is tested
/// without a scroll view.
///
/// The view follows the newest turn until the wearer scrolls back to read; then a new line no
/// longer moves what they are reading. Scrolling back down to the bottom picks it up again. Only
/// the wearer's own scrolling changes it: the view's scroll to a new line, and the list growing,
/// leave it as it was.
struct CaptionFollowRule: Equatable {

    /// Within this many points of the bottom counts as at the bottom, so a line's descender or a
    /// bounce does not read as scrolling back.
    static let bottomTolerance: CGFloat = 24

    private(set) var isFollowing = true
    private(set) var wearerScrolling = false

    /// Whether a new turn should scroll the view to it.
    var followsNewTurn: Bool { isFollowing && !wearerScrolling }

    /// The wearer put a finger on the list. While they drag, nothing moves under it.
    mutating func wearerBeganScrolling() {
        wearerScrolling = true
    }

    /// The list moved while the wearer was scrolling it.
    mutating func scrolled(atBottom: Bool) {
        guard wearerScrolling else { return }
        isFollowing = atBottom
    }

    /// The wearer let go and the list came to rest: following again only if it rests at the bottom.
    mutating func wearerStoppedScrolling(atBottom: Bool) {
        wearerScrolling = false
        isFollowing = atBottom
    }

    static func isAtBottom(contentOffsetY: CGFloat, visibleHeight: CGFloat,
                           contentHeight: CGFloat) -> Bool {
        // Content shorter than the window is always at its bottom.
        guard contentHeight > visibleHeight else { return true }
        return contentOffsetY + visibleHeight >= contentHeight - bottomTolerance
    }
}

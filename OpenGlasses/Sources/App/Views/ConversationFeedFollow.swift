import Foundation

/// Where the Voice tab's feed keeps itself when something new arrives: the newest line, or the top
/// of the manual page that was just put in front of the technician.
///
/// The feed used to follow only the newest line. A cited page opens *under* the answer, so tapping
/// the citation, or saying "show me the page" while that page was already open further down, moved
/// nothing on screen — the page was there, below the fold, and the wearer saw no response. Now a
/// page being shown is the newest thing, and the feed holds it in view for the rest of that turn:
/// the reply that says "page 19 is open" streams in above it without pulling the page back out of
/// sight. The next turn — the wearer speaking or typing again — goes back to following the newest
/// line, as does closing the page.
struct ConversationFeedFollow: Equatable {
    enum Target: Equatable {
        /// The bottom of the feed: the newest line of the conversation, or whatever trails it.
        case newest
        /// The top of the manual page under the conversation.
        case pageTop
    }

    /// The scroll id the page under the conversation tags its top with.
    static let pageAnchor = "voice-feed-trail-top"

    /// True from a page being shown until the next turn starts or the page closes.
    private(set) var holdsPage = false

    /// A page was put in front of the technician — opened, or asked for again while open.
    mutating func pageShown() { holdsPage = true }

    /// The wearer started a new turn: what they say next is what they want to read.
    mutating func turnStarted() { holdsPage = false }

    /// The page closed; there is nothing to hold.
    mutating func pageClosed() { holdsPage = false }

    /// Where a scroll for new content should land, given whether a page is drawn in the feed.
    func target(pageOnScreen: Bool) -> Target {
        holdsPage && pageOnScreen ? .pageTop : .newest
    }
}

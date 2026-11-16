import XCTest
@testable import OpenGlasses

/// The Voice tab's feed holds a page that was just shown in view for the rest of the turn, so
/// tapping a citation or asking for the page again visibly lands on it.
final class ConversationFeedFollowTests: XCTestCase {

    func testFollowsTheNewestLineByDefault() {
        let follow = ConversationFeedFollow()
        XCTAssertEqual(follow.target(pageOnScreen: false), .newest)
        XCTAssertEqual(follow.target(pageOnScreen: true), .newest,
                       "an open page the wearer has scrolled past is not pulled back by new lines")
    }

    func testAShownPageIsHeldForTheRestOfTheTurn() {
        var follow = ConversationFeedFollow()
        follow.pageShown()
        // The reply saying "page 19 is open" streams in after the page: it must not scroll away.
        XCTAssertEqual(follow.target(pageOnScreen: true), .pageTop)
        XCTAssertEqual(follow.target(pageOnScreen: true), .pageTop)
    }

    func testTheNextTurnFollowsTheNewestLineAgain() {
        var follow = ConversationFeedFollow()
        follow.pageShown()
        follow.turnStarted()
        XCTAssertEqual(follow.target(pageOnScreen: true), .newest)
    }

    func testClosingThePageLetsGo() {
        var follow = ConversationFeedFollow()
        follow.pageShown()
        follow.pageClosed()
        XCTAssertEqual(follow.target(pageOnScreen: true), .newest)
    }

    func testNoPageOnScreenMeansNothingToHold() {
        var follow = ConversationFeedFollow()
        follow.pageShown()
        // The expanded workspace draws the page in its context pane, not in the feed.
        XCTAssertEqual(follow.target(pageOnScreen: false), .newest)
    }

    func testAskingAgainAfterATurnHoldsThePageAgain() {
        var follow = ConversationFeedFollow()
        follow.pageShown()
        follow.turnStarted()
        follow.pageShown()   // "show me the page" while it is already open
        XCTAssertEqual(follow.target(pageOnScreen: true), .pageTop)
    }
}

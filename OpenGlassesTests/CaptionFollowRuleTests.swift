import XCTest
@testable import OpenGlasses

/// Plan KP P5 — the live captions follow the newest line unless the wearer has scrolled back to
/// read, and pick it up again once they are back at the bottom.
final class CaptionFollowRuleTests: XCTestCase {

    func testANewViewFollowsTheNewestLine() {
        XCTAssertTrue(CaptionFollowRule().followsNewTurn)
    }

    func testScrollingBackStopsFollowing() {
        var rule = CaptionFollowRule()
        rule.wearerBeganScrolling()
        XCTAssertFalse(rule.followsNewTurn, "nothing moves under the wearer's finger")
        rule.scrolled(atBottom: false)
        rule.wearerStoppedScrolling(atBottom: false)
        XCTAssertFalse(rule.followsNewTurn)
        XCTAssertFalse(rule.isFollowing)
    }

    func testNewLinesAndTheViewsOwnScrollingLeaveAWearerWhoScrolledBackWhereTheyAre() {
        var rule = CaptionFollowRule()
        rule.wearerBeganScrolling()
        rule.wearerStoppedScrolling(atBottom: false)
        // The list growing, or a programmatic move, reports geometry without the wearer touching it.
        rule.scrolled(atBottom: true)
        XCTAssertFalse(rule.followsNewTurn)
    }

    func testScrollingBackToTheBottomFollowsAgain() {
        var rule = CaptionFollowRule()
        rule.wearerBeganScrolling()
        rule.wearerStoppedScrolling(atBottom: false)
        rule.wearerBeganScrolling()
        rule.scrolled(atBottom: true)
        rule.wearerStoppedScrolling(atBottom: true)
        XCTAssertTrue(rule.followsNewTurn)
    }

    func testATouchThatLeavesTheViewAtTheBottomKeepsFollowing() {
        var rule = CaptionFollowRule()
        rule.wearerBeganScrolling()
        rule.wearerStoppedScrolling(atBottom: true)
        XCTAssertTrue(rule.followsNewTurn)
    }

    func testAtTheBottomAllowsALittleSlack() {
        XCTAssertTrue(CaptionFollowRule.isAtBottom(contentOffsetY: 200, visibleHeight: 100, contentHeight: 300))
        XCTAssertTrue(CaptionFollowRule.isAtBottom(contentOffsetY: 180, visibleHeight: 100, contentHeight: 300))
        XCTAssertFalse(CaptionFollowRule.isAtBottom(contentOffsetY: 150, visibleHeight: 100, contentHeight: 300))
    }

    func testContentShorterThanTheWindowIsAlwaysAtTheBottom() {
        XCTAssertTrue(CaptionFollowRule.isAtBottom(contentOffsetY: 0, visibleHeight: 100, contentHeight: 40))
    }
}

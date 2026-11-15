import XCTest

/// Plan LU P1b — a private conversation started from the conversation page's header, driven the
/// way a wearer drives it: the badge shows, End ends it, and the History list has nothing new in it.
///
/// Nothing is said or typed: the simulator has no model to answer, and what a private turn writes
/// is covered headlessly (`PrivateConversationTraceTests`). What only a screen can show is that the
/// page says Private while it is, that End reaches the wearer, and that starting one lists nothing.
final class PrivateConversationUITests: AccessibilityAuditCase {

    func testStartingFromTheHeaderShowsTheBadgeAndEndingListsNothing() {
        let app = launch([.configured, .seedConversations])
        awaitScreen(app.tabBars.buttons["Avenkin"], named: "The tab bar")

        // What History lists before.
        openTab("History", in: app)
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "History lists none of the seeded conversations")
        let listedBefore = app.cells.count

        // Start one from the header's new-conversation menu (held, it offers the private start).
        openTab("Avenkin", in: app)
        let newConversation = app.buttons["conversationHeaderNewConversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 30),
                      "The conversation page's header has no new-conversation button")
        newConversation.press(forDuration: 1.2)
        let start = app.buttons["Start a private conversation"]
        XCTAssertTrue(start.waitForExistence(timeout: 10),
                      "The header's menu doesn't offer a private conversation")
        start.tap()

        // The first private conversation on a phone explains itself, once.
        let explainerOK = app.alerts.buttons["OK"]
        if explainerOK.waitForExistence(timeout: 5) { explainerOK.tap() }

        let badge = app.buttons["privateConversationBadge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "The header shows no Private badge")
        XCTAssertEqual(badge.label, "Private conversation. Nothing of it is kept.")

        // The badge offers End.
        badge.tap()
        let end = app.buttons["End"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "Tapping the badge doesn't offer End")
        end.tap()

        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: badge)
        wait(for: [gone], timeout: 10)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Conversation:"))
            .firstMatch.waitForExistence(timeout: 10),
                      "After End the header doesn't name the conversation again")

        // Nothing was listed.
        openTab("History", in: app)
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(app.cells.count, listedBefore, "A private conversation left a row in History")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Private"))
            .firstMatch.exists, "History mentions the private conversation")
    }
}

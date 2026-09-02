import XCTest

/// The dock's conversation page, driven the way a wearer drives it.
///
/// This exists because of a device report the unit suite could not have caught: picking an earlier
/// conversation from the switcher left the page reading "Nothing said yet." The store had been
/// resumed and the model had its history — the page simply never rendered a stored message, only
/// the live turn's two cards. Everything about that is invisible to a headless test, because both
/// halves were individually correct.
final class ConversationPageTests: AccessibilityAuditCase {

    /// A line from the older seeded conversation (see `UITestSupport.longExchange`).
    private let seededReply = "It's galvanised steel"
    private let seededQuestion = "What's the flashing on the roof made of?"

    func testPickingAConversationShowsWhatWasSaidInIt() {
        let app = launch([.configured, .seedConversations])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        openConversationPage(app)
        let header = conversationHeader(app)
        XCTAssertTrue(header.waitForExistence(timeout: 10),
                      "The conversation page has no header naming the conversation")
        header.tap()

        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "flashing")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "The switcher does not list the seeded conversation")
        row.tap()

        // The whole point: after picking it, the page shows what is *in* it.
        XCTAssertTrue(
            waitForText(app, containing: seededReply, timeout: 15),
            "Picking a conversation left the page showing none of its messages — the resumed "
            + "thread is active invisibly, which is exactly the reported defect."
        )
        XCTAssertTrue(
            waitForText(app, containing: seededQuestion, timeout: 5),
            "The wearer's own side of the resumed conversation is missing"
        )
        XCTAssertFalse(app.staticTexts["Nothing said yet."].exists,
                       "A conversation with messages in it is still drawing the empty state")
    }

    /// The other half of the same mechanism: a finished voice turn ends its thread, so the page
    /// offers to carry on with it. Taking the offer has to render the conversation too.
    func testCarryingOnWithTheLastConversationShowsIt() {
        let app = launch([.configured, .seedConversations])
        awaitScreen(app.tabBars.buttons["Voice"], named: "The tab bar")

        openConversationPage(app)
        let carryOn = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Carry on with")
        ).firstMatch
        XCTAssertTrue(carryOn.waitForExistence(timeout: 10),
                      "With conversations stored and none active, the page offers no way back "
                      + "into the last one")
        carryOn.tap()

        // An assistant line, deliberately: a thread's *title* is generated from its first user
        // message, so asserting on the question would pass on the header alone and prove nothing
        // about the transcript.
        XCTAssertTrue(waitForText(app, containing: "It closes at 5:30", timeout: 15),
                      "Carrying on with the last conversation showed none of it")
    }

    // MARK: - Driving the pager

    /// The grid is the pager's home page and the conversation is one swipe left of it.
    ///
    /// Swiped up to three times before giving up. A paging `TabView` under a loaded machine drops
    /// the occasional gesture, and a dropped swipe is not the thing this file is here to catch —
    /// it would fail as "no header", which reads exactly like the bug and is not it.
    private func openConversationPage(_ app: XCUIApplication) {
        let dock = app.otherElements["Dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 30), "The dock panel never appeared")
        for _ in 0..<3 {
            if conversationHeader(app).waitForExistence(timeout: 3) { return }
            dock.swipeRight()
        }
    }

    private func conversationHeader(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Conversation:")
        ).firstMatch
    }

    /// Text on this surface is drawn as static text and, inside a bubble, reaches the tree as the
    /// bubble's own combined label — so both are worth asking.
    private func waitForText(_ app: XCUIApplication, containing needle: String,
                             timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
        let text = app.staticTexts.matching(predicate).firstMatch
        if text.waitForExistence(timeout: timeout) { return true }
        return app.descendants(matching: .any).matching(predicate).firstMatch.exists
    }
}

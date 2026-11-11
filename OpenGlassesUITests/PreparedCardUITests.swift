import XCTest

/// Plan KT P1 — "edit, hand off, cancel, still there": a card's draft edited on the My Day page goes
/// to the composer as edited, and cancelling the composer leaves the card on the page with the
/// edit. The simulator has no Messages composer, so `standInComposer` puts a plain sheet where it
/// would be; the card's own path — the edit kept in the store, the hand-off, the cancelled result —
/// is the shipping one. Invented person and number only.
final class PreparedCardUITests: AccessibilityAuditCase {

    func testEditHandOffCancelStillThere() {
        let app = launch([.configured, .seedMyDay, .seedPreparedCard, .standInComposer])

        // The home card shows the top card and "1 more ready", which opens the page.
        let more = app.buttons["1 more ready"]
        awaitScreen(more, named: "The home card's ready cards")
        more.tap()
        awaitScreen(app.navigationBars["My Day"], named: "The My Day page")

        let draft = app.textViews["preparedCard.draft"].firstMatch
        awaitScreen(draft, named: "The card's draft")
        draft.tap()
        draft.typeText(" Leaving now.")
        let edited = (draft.value as? String) ?? ""
        XCTAssertTrue(edited.contains("Leaving now."), edited)

        // Hand off: the composer opens with the edited text.
        let handOff = app.buttons["Text Ana"]
        awaitScreen(handOff, named: "The hand-off button")
        handOff.tap()
        let body = app.staticTexts["draftComposer.body"]
        awaitScreen(body, named: "The composer")
        XCTAssertTrue(body.label.contains("Leaving now."), "the composer carries the edit: \(body.label)")

        // Cancel: the card is still there, edit and all.
        app.buttons["draftComposer.cancel"].tap()
        XCTAssertTrue(app.buttons["Text Ana"].waitForExistence(timeout: 10), "the card is still on the page")
        let after = (app.textViews["preparedCard.draft"].firstMatch.value as? String) ?? ""
        XCTAssertTrue(after.contains("Leaving now."), "the edit is kept: \(after)")
    }
}

import XCTest

/// Plan LW P1 — the draft review screen on a vault made on the phone: a reply pasted from the
/// author's own AI is read and checked against the manual, each row shows its mark, a line that is
/// not a row is shown as it is, and a checked row is kept into the vault's fault-code file.
///
/// The vault is made by the shipping New Vault path and the manual added by the shipping Add manual
/// path (`UITestVaultAuthoring`); the screen is drawn over the app. Every name, code and model is
/// invented.
final class VaultAuthoringUITests: AccessibilityAuditCase {

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testAPastedReplyIsCheckedAndACheckedRowIsKept() {
        let app = launch([.configured, .vaultAuthoring])
        let paste = app.textViews["draftReview.paste"]
        awaitScreen(paste, named: "The paste field")

        paste.tap()
        paste.typeText("Here are the codes I found:\nE9 | Low suction pressure | 2\nF17 | Fan motor overload | 5")
        let done = app.buttons["draftReview.keyboardDone"]
        if done.waitForExistence(timeout: 5) { done.tap() }

        let check = app.buttons["draftReview.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 10), "No Check pasted rows button")
        check.tap()

        let keep = app.buttons["draftReview.keep.e9"]
        awaitScreen(keep, named: "The E9 row's Keep button", timeout: 20)
        XCTAssertTrue(element(containing: "Checked · page 2", in: app).exists, "E9 isn't marked checked on page 2")
        XCTAssertTrue(element(containing: "Found on page 2", in: app).exists,
                      "F17, cited on a page it isn't on, doesn't say where it was found")
        XCTAssertTrue(element(containing: "Here are the codes I found:", in: app).exists,
                      "The line that isn't a row was dropped instead of shown")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lw-draft-review-marks"
        shot.lifetime = .keepAlways
        add(shot)

        if !keep.isHittable { app.swipeUp() }
        keep.tap()
        let kept = app.descendants(matching: .any)["draftReview.kept.e9"]
        awaitScreen(kept, named: "The kept row's confirmation", timeout: 10)
        XCTAssertTrue(kept.label.contains("fault-codes.md"), kept.label)
    }
}

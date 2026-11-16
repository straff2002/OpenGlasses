import XCTest

/// Plan LW P1 — the draft review screen on a vault made on the phone: a reply from the author's own
/// AI, in the paste field, is read and checked against the manual, each row shows its mark, a line that is
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
        // The configured launch can raise the cloud-sharing consent over everything; this test is
        // about the draft screen beneath it, and nothing here is sent anywhere.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 15) {
            notNow.tap()
            _ = notNow.waitForNonExistence(timeout: 10)
        }
        let paste = app.descendants(matching: .any)["draftReview.paste"]
        if !paste.waitForExistence(timeout: 60) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "lw-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        awaitScreen(paste, named: "The paste field", timeout: 1)

        XCTAssertTrue((paste.value as? String)?.contains("E9 | Low suction pressure | 2") == true,
                      "The fixture's reply isn't in the paste field")

        let check = app.buttons["draftReview.check"]
        XCTAssertTrue(check.waitForExistence(timeout: 10), "No Check pasted rows button")
        check.tap()

        // The checked rows are drawn below the paste field; a form only builds the rows on screen.
        let keep = app.buttons["draftReview.keep.e9"]
        for _ in 0..<6 where !keep.waitForExistence(timeout: 3) { app.swipeUp() }
        awaitScreen(keep, named: "The E9 row's Keep button", timeout: 5)
        XCTAssertTrue(element(containing: "Checked · page 2", in: app).exists, "E9 isn't marked checked on page 2")
        let found = element(containing: "Found on page 2", in: app)
        for _ in 0..<3 where !found.exists { app.swipeUp() }
        XCTAssertTrue(found.exists, "F17, cited on a page it isn't on, doesn't say where it was found")
        let unparsed = element(containing: "Here are the codes I found:", in: app)
        for _ in 0..<3 where !unparsed.exists { app.swipeUp() }
        XCTAssertTrue(unparsed.exists,
                      "The line that isn't a row was dropped instead of shown")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lw-draft-review-marks"
        shot.lifetime = .keepAlways
        add(shot)

        for _ in 0..<6 where !keep.isHittable { app.swipeDown() }
        keep.tap()
        let kept = element(containing: "Kept in fault-codes.md", in: app)
        awaitScreen(kept, named: "The kept row's confirmation", timeout: 10)
        XCTAssertFalse(app.buttons["draftReview.keep.e9"].exists, "A kept row still offers Keep")
    }
}

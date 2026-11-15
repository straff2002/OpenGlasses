import XCTest

/// Plan LV P1 — a published vault's row as the managed section draws it: whose vault it is and at
/// which of the partner's versions, the manual checklist, and the list the checklist opens.
///
/// The rows are the shipping `CompanyVaultRow.rows` over fixture state, drawn by the shipping view
/// (`UITestPublishedVaultRows`): an organisation profile cannot be enrolled in a UI test without a
/// key no build holds, so none is faked. Every name is invented.
final class PublishedVaultRowUITests: AccessibilityAuditCase {

    /// Rows combine their lines into one element, as their neighbours do, so a line is found inside
    /// the label it is part of.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testThePublishedRowShowsThePartnerTheVersionAndTheChecklist() {
        let app = launch([.configured, .publishedVaultRows])
        let row = element(containing: "from Fixture Partner · version 5", in: app)
        awaitScreen(row, named: "The published vault's row")
        XCTAssertTrue(row.label.hasPrefix("Fixture Split Systems"), row.label)
        XCTAssertTrue(element(containing: "Adds to Fixture Split Systems", in: app).exists,
                      "The company layer's row doesn't say what it adds to")

        let checklist = app.buttons["companyVaultChecklist.fixture-split-systems"]
        XCTAssertTrue(checklist.waitForExistence(timeout: 10), "The row has no manual checklist")
        XCTAssertEqual(checklist.label, "2 of 3 manuals · 1 a different revision · 1 missing")
        XCTAssertTrue(checklist.isHittable)

        checklist.tap()
        awaitScreen(element(containing: "Wiring diagram (2024)", in: app), named: "The checklist's list of manuals")
        XCTAssertTrue(element(containing: "Wiring diagram (2024)", in: app).label.contains("Missing"))
        XCTAssertTrue(element(containing: "Service manual (Rev B)", in: app).label.contains("A different revision"))
        XCTAssertTrue(element(containing: "Installation manual (Rev C)", in: app).label.contains("Held"))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "lv-published-vault-checklist"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

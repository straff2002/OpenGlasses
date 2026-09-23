import XCTest

/// Plan FO P3b — photographs of the three screens the debrief and the delivery queue add, in both
/// appearances and at the largest text size.
///
/// Not an audit: these exist so a person can look at a past job's Debrief section, the reports
/// waiting to send and the read-back a technician is asked to confirm, and say whether they read.
/// Everything is the shipping flow with only the job's state seeded.
///
/// Set `OG_SHOT_DIR` to write the PNGs somewhere as well as attaching them to the result bundle.
final class JobDebriefScreenshotTests: AccessibilityAuditCase {

    private func save(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OG_SHOT_DIR"] ?? environment["TEST_RUNNER_OG_SHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    // MARK: - A past job's debrief

    func testThePastJobDebriefLight() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends])
        openThePastJob(app)
        save(app, named: "fo3b-past-job-debrief-light")
    }

    func testThePastJobDebriefDark() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends, .darkAppearance])
        openThePastJob(app)
        save(app, named: "fo3b-past-job-debrief-dark")
    }

    func testThePastJobDebriefAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends],
                         contentSizeCategory: Self.ax5)
        openThePastJob(app)
        save(app, named: "fo3b-past-job-debrief-ax5")
    }

    // MARK: - The reports waiting to send

    func testTheSendCardLight() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends])
        openTheJobTab(app)
        save(app, named: "fo3b-send-card-light")
    }

    func testTheSendCardDark() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends, .darkAppearance])
        openTheJobTab(app)
        save(app, named: "fo3b-send-card-dark")
    }

    func testTheSendCardAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends],
                         contentSizeCategory: Self.ax5)
        openTheJobTab(app)
        save(app, named: "fo3b-send-card-ax5")
    }

    // MARK: - The read-back

    /// The debrief sheet as it opens on the phone: the job, and the offer to write it up. The
    /// summary itself needs a model, which a UI test has none of — so what is photographed is the
    /// screen a technician actually meets first.
    func testTheDebriefSheetLight() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends])
        openTheDebriefSheet(app)
        save(app, named: "fo3b-debrief-sheet-light")
    }

    func testTheDebriefSheetDark() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends, .darkAppearance])
        openTheDebriefSheet(app)
        save(app, named: "fo3b-debrief-sheet-dark")
    }

    func testTheDebriefSheetAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends],
                         contentSizeCategory: Self.ax5)
        openTheDebriefSheet(app)
        save(app, named: "fo3b-debrief-sheet-ax5")
    }

    // MARK: - Getting there

    private func openTheJobTab(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Job"]
        XCTAssertTrue(tab.waitForExistence(timeout: 120), "the Job tab never appeared")
        tab.tap()
        _ = app.staticTexts["3 reports ready to send"].waitForExistence(timeout: 30)
    }

    private func openThePastJob(_ app: XCUIApplication) {
        openTheJobTab(app)
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Job 1004")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "the past job row never came into reach")
        row.tap()
        for _ in 0..<8 where !app.staticTexts["Debrief"].exists { app.swipeUp() }
        _ = app.staticTexts["Debrief"].waitForExistence(timeout: 20)
    }

    private func openTheDebriefSheet(_ app: XCUIApplication) {
        openThePastJob(app)
        let start = app.buttons["Debrief this job"]
        for _ in 0..<8 where !(start.exists && start.isHittable) { app.swipeUp() }
        XCTAssertTrue(start.exists, "the Debrief action never came into reach")
        start.tap()
        _ = app.navigationBars["Debrief"].waitForExistence(timeout: 20)
    }

    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
}

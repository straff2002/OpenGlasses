import XCTest

/// Plan FO P3b — photographs of the three screens the debrief and the delivery queue add, in both
/// appearances and at the largest text size.
///
/// Not an audit: these exist so a person can look at a past job's Debrief section, the reports
/// waiting to send and the read-back a technician is asked to confirm, and say whether they read.
/// Everything is the shipping flow with only the job's state seeded.
///
/// Set `OG_SHOT_DIR` to write the PNGs somewhere as well as attaching them to the result bundle;
/// every shot is also an attachment on the result bundle either way.
///
/// **Only the Send card is photographed at the largest accessibility size.** At AX5 that card is
/// taller than the screen on its own, so the past-jobs list below it is past what a UI test can
/// scroll a lazily-built `List` to — the two screens behind it are photographed at the default
/// size in both appearances instead. Their AX5 *layout* is what the accessibility audits in
/// `JobTabAccessibilityTests` measure, which is the claim that actually matters.
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

    // MARK: - Getting there

    /// Open the Job tab, with the one clean restart `JobTabAccessibilityTests.openJobTab` exists
    /// for: the first launch of a run installs a large Debug build and starts it cold, and on a
    /// loaded host the seeded state occasionally never lands.
    private func openTheJobTab(_ app: XCUIApplication) {
        var tab = app.tabBars.buttons["Job"]
        if !tab.waitForExistence(timeout: 90) {
            app.terminate()
            app.launch()
            tab = app.tabBars.buttons["Job"]
            XCTAssertTrue(tab.waitForExistence(timeout: 150),
                          "the Job tab never appeared, even after a clean restart. Tab bar: "
                          + "\(app.tabBars.buttons.allElementsBoundByIndex.map(\.label))")
        }
        tab.tap()
        _ = app.staticTexts["3 reports ready to send"].waitForExistence(timeout: 30)
    }

    /// Swipe until the element is reachable. Generous at AX5, where every row is several times
    /// taller and a `List` builds its rows lazily — an element below the fold does not merely sit
    /// off-screen, it does not exist yet.
    private func reach(_ element: XCUIElement, in app: XCUIApplication, named name: String,
                       swipes: Int = 20) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(name) never came into reach after \(swipes) swipes")
    }

    /// Reach the finished job through the list's own search field rather than by scrolling.
    ///
    /// At the largest accessibility size the reports-ready card alone is taller than the screen,
    /// so the past-jobs list is a long way down — and a `List` has not built a row that far below
    /// the fold. Searching is what a technician would do anyway, and it is deterministic.
    private func openThePastJob(_ app: XCUIApplication) {
        openTheJobTab(app)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 20) {
            field.tap()
            field.typeText("1004")
        }
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Job 1004")).firstMatch
        reach(row, in: app, named: "The past job row")
        row.tap()
        let block = app.staticTexts["Debrief"]
        reach(block, in: app, named: "The debrief section")
    }

    private func openTheDebriefSheet(_ app: XCUIApplication) {
        openThePastJob(app)
        let start = app.buttons["Debrief this job"]
        reach(start, in: app, named: "The Debrief action")
        start.tap()
        _ = app.navigationBars["Debrief"].waitForExistence(timeout: 30)
    }

    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
}

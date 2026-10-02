import XCTest

/// Plan HB — the Modes tab becoming Field Assist, the shortcut it carries when Field Assist is off,
/// and the home screen's job-day card with the day view behind it. Each case asserts the shape and
/// photographs it (set `OG_SHOT_DIR` to write the PNGs out as well as attaching them), and the Field
/// Assist tab and the day view are audited.
final class FieldAssistModeUITests: AccessibilityAuditCase {

    private var formDeferrals: [AuditDeferral] {
        [.systemFormChrome, .secondaryCopyContrast, .singleLineTextEntry]
    }

    private func save(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OG_SHOT_DIR"] ?? environment["TEST_RUNNER_OG_SHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication,
                                    named name: String, swipes: Int = 8,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(name) never came into reach after \(swipes) swipes", file: file, line: line)
    }

    // MARK: - Field Assist off

    /// Without Field Assist the slot is Modes, and its first row leads to Settings › Field Assist.
    func testModesCarriesTheFieldAssistShortcut() {
        let app = launch([.configured])
        openTab("Modes", in: app)
        XCTAssertFalse(app.tabBars.buttons["Field Assist"].exists)

        let shortcut = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Field Assist.")).firstMatch
        awaitScreen(shortcut, named: "The Field Assist row on Modes")
        save(app, named: "hb-modes-shortcut")

        shortcut.tap()
        awaitScreen(app.switches["Enable Field Assist"], named: "Settings › Field Assist")
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected,
                      "the shortcut opens Field Assist inside Settings, not a copy of it")
        save(app, named: "hb-modes-shortcut-opened")
    }

    // MARK: - Field Assist on

    func testTheModesTabBecomesFieldAssist() {
        let app = launch([.configured, .fieldAssist])
        let tab = app.tabBars.buttons["Field Assist"]
        awaitScreen(tab, named: "The Field Assist tab", timeout: 90)
        XCTAssertFalse(app.tabBars.buttons["Modes"].exists, "the slot is Field Assist, not a second tab")
        tab.tap()

        awaitScreen(app.navigationBars["Field Assist"], named: "The Field Assist tab's page")
        XCTAssertTrue(app.staticTexts["Scenarios"].exists || app.staticTexts["SCENARIOS"].exists)
        save(app, named: "hb-field-assist-tab")
        audit(app, screen: "Field Assist tab",
              deferring: formDeferrals + [AuditDeferral.contentUnderTheTabBar(of: app)])

        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Other modes")).firstMatch
        scrollUntilVisible(other, in: app, named: "Other modes")
        XCTAssertEqual(other.value as? String, "Collapsed", "the other modes rest minimised")
        save(app, named: "hb-field-assist-other-modes-collapsed")

        other.tap()
        let personas = app.staticTexts.matching(NSPredicate(format: "label IN %@",
            ["Active Personas", "ACTIVE PERSONAS", "Available Modes", "AVAILABLE MODES", "No Personas"])).firstMatch
        scrollUntilVisible(personas, in: app, named: "The persona picker under Other modes")
        save(app, named: "hb-field-assist-other-modes-expanded")
    }

    // MARK: - The job-day card

    func testTheJobDayCardAndTheDayBehindIt() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends, .seedFieldDay, .seedMyDay])
        openTab("Avenkin", in: app)

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Today,")).firstMatch
        awaitScreen(card, named: "The job-day card", timeout: 90)
        save(app, named: "hb-job-day-collapsed")
        XCTAssertFalse(app.buttons["Expand My Day"].exists || app.buttons["Collapse My Day"].exists,
                       "with Field Assist on, My Day's own card gives way to the job-day card")

        let expand = app.buttons["Expand today's jobs"]
        if expand.exists {
            expand.tap()
            awaitScreen(app.buttons["Collapse today's jobs"], named: "The open card")
        }
        save(app, named: "hb-job-day-expanded")

        card.tap()
        awaitScreen(app.navigationBars["Today"], named: "The day view")
        save(app, named: "hb-job-day-view")
        audit(app, screen: "Job day view", deferring: formDeferrals)
        // My Day is on in this launch, so its items are folded in below the job admin — one card,
        // not two.
        let myDay = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["My Day", "MY DAY"])).firstMatch
        // A section header is in the tree but not hittable, so this checks presence after a swipe
        // rather than reach.
        app.swipeUp()
        XCTAssertTrue(myDay.waitForExistence(timeout: 10), "My Day's items are not folded into the day")
        save(app, named: "hb-job-day-view-my-day")

        app.navigationBars["Today"].buttons["Done"].tap()
        awaitScreen(card, named: "The card, after Done")
    }

    /// A job in the day view opens over the Jobs list (Plan HC): the Jobs tab is selected, the
    /// job's page is up, and Back is the list of every job.
    func testAJobInTheDayOpensOverTheJobsList() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSends, .seedFieldDay, .seedMyDay])
        openTab("Avenkin", in: app)

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Today,")).firstMatch
        if !card.waitForExistence(timeout: 90) {
            // First launch of a run, cold: the seeded day occasionally never lands. One clean
            // restart, as the Job tab's own tests do.
            app.terminate()
            app.launch()
            openTab("Avenkin", in: app)
        }
        awaitScreen(card, named: "The job-day card", timeout: 90)
        card.tap()
        awaitScreen(app.navigationBars["Today"], named: "The day view")

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Job 1006")).firstMatch
        awaitScreen(row, named: "Job 1006 in the day")
        row.tap()

        let page = app.navigationBars["Job 1006"]
        awaitScreen(page, named: "Job 1006's page in the Jobs tab")
        XCTAssertTrue(app.tabBars.buttons["Jobs"].isSelected, "the Jobs tab is the one showing")
        save(app, named: "hc-day-row-opens-job")

        page.buttons["Jobs"].tap()
        awaitScreen(app.buttons["Add new job"], named: "The Jobs list, after Back")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Job 1006,"))
            .firstMatch.exists, "the job is on the list it came back to")
    }
}

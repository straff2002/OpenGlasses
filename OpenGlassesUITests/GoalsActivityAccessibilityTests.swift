import XCTest

/// Plan IW P2 — the Goals and Activity screens, audited empty and populated, at the default text
/// size and at AX5, with a screenshot of each in light and dark.
///
/// Every UI-test launch starts with no goals and no trail (`UITestSupport` clears both), so the
/// empty states are what a launch without `seedGoals` shows; `seedGoals` writes one goal two steps
/// in and a morning's trail through the shipping stores.
final class GoalsActivityAccessibilityTests: AccessibilityAuditCase {

    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    /// The deferrals any `Form` screen in this app carries, plus the tab bar over the last rows.
    private func deferrals(_ app: XCUIApplication) -> [AuditDeferral] {
        [.systemFormChrome, .secondaryCopyContrast, .singleLineTextEntry, .contentUnderTheTabBar(of: app)]
    }

    // MARK: - Getting there

    /// Settings → Everyday, the Memory group's details unfolded, then the row, scrolled into reach.
    /// Goals and Activity are links in the Memory group, which is a switch with its rows folded
    /// under "Details" until opened.
    private func open(_ row: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        openTab("Settings", in: app, file: file, line: line)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub", file: file, line: line)
        tapRow(startingWith: "Everyday", in: app, file: file, line: line)
        awaitScreen(app.navigationBars["Everyday"], named: "Everyday", file: file, line: line)
        let details = app.buttons["Memory details"]
        reach(details, in: app, named: "The Memory group's details", file: file, line: line)
        details.tap()
        let link = app.buttons[row]
        reach(link, in: app, named: "The \(row) row", file: file, line: line)
        link.tap()
        awaitScreen(app.navigationBars[row], named: "The \(row) screen", file: file, line: line)
    }

    private func reach(_ element: XCUIElement, in app: XCUIApplication, named name: String,
                       swipes: Int = 12, file: StaticString = #filePath, line: UInt = #line) {
        _ = element.waitForExistence(timeout: 5)
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable,
                      "\(name) never came into reach after \(swipes) swipes", file: file, line: line)
    }

    private func back(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A screenshot as an attachment, and — when `OG_SHOT_DIR` names a directory — a PNG there.
    private func save(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OG_SHOT_DIR"] ?? environment["TEST_RUNNER_OG_SHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // MARK: - Empty

    private func auditEmpty(size: String?, appearance: String, audits: Bool) {
        var states: [LaunchState] = [.configured]
        if appearance == "dark" { states.append(.darkAppearance) }
        let app = launch(states, contentSizeCategory: size)
        let suffix = size == nil ? appearance : "ax5-\(appearance)"

        open("Goals", in: app)
        awaitScreen(app.staticTexts["No goals yet"], named: "The goals empty state")
        XCTAssertTrue(app.buttons["Add a goal"].exists, "with the goals tool on, the empty state offers to add one")
        save(app, named: "iw-goals-empty-\(suffix)")
        if audits { audit(app, screen: "Goals — empty (\(suffix))", deferring: deferrals(app)) }

        back(in: app)
        let activity = app.buttons["Activity"]
        reach(activity, in: app, named: "The Activity row")
        activity.tap()
        awaitScreen(app.staticTexts["Nothing yet"], named: "The activity empty state")
        XCTAssertTrue(element(containing: "never records what you said", in: app).exists,
                      "the empty state says the trail is the assistant's actions only")
        save(app, named: "iw-activity-empty-\(suffix)")
        if audits { audit(app, screen: "Activity — empty (\(suffix))", deferring: deferrals(app)) }
    }

    func testGoalsAndActivityEmptyStates() {
        auditEmpty(size: nil, appearance: "light", audits: true)
    }

    func testGoalsAndActivityEmptyStatesAtAX5() {
        auditEmpty(size: Self.ax5, appearance: "light", audits: true)
    }

    func testGoalsAndActivityEmptyStatesInDark() {
        auditEmpty(size: nil, appearance: "dark", audits: false)
    }

    // MARK: - Populated

    private func auditPopulated(size: String?, appearance: String, audits: Bool) {
        var states: [LaunchState] = [.configured, .seedGoals]
        if appearance == "dark" { states.append(.darkAppearance) }
        let app = launch(states, contentSizeCategory: size)
        let suffix = size == nil ? appearance : "ax5-\(appearance)"

        open("Goals", in: app)
        let goal = element(containing: "Clear the garage", in: app)
        awaitScreen(goal, named: "The seeded goal's row")
        XCTAssertTrue(element(containing: "1 of 4 steps done", in: app).exists, "the row says its progress")
        save(app, named: "iw-goals-list-\(suffix)")
        if audits { audit(app, screen: "Goals — one goal (\(suffix))", deferring: deferrals(app)) }

        goal.tap()
        awaitScreen(app.navigationBars["Clear the garage"], named: "The goal's page")
        save(app, named: "iw-goal-detail-\(suffix)")
        // Below the fold at AX5, and a `Form` builds only the rows it has reached.
        reach(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search for it")).firstMatch,
              in: app, named: "The next step's suggested search")
        if audits { audit(app, screen: "Goal page (\(suffix))", deferring: deferrals(app)) }

        back(in: app)
        back(in: app)
        let activity = app.buttons["Activity"]
        reach(activity, in: app, named: "The Activity row")
        activity.tap()
        // The newest row leads; at AX5 the rest of the morning is below the fold.
        awaitScreen(element(containing: "Your OK to use the send message tool", in: app), named: "The seeded trail")
        XCTAssertTrue(element(containing: "Held for you", in: app).exists, "authorisation is said in words")
        save(app, named: "iw-activity-\(suffix)")
        if audits { audit(app, screen: "Activity — a morning (\(suffix))", deferring: deferrals(app)) }
    }

    func testGoalsAndActivityPopulated() {
        auditPopulated(size: nil, appearance: "light", audits: true)
    }

    func testGoalsAndActivityPopulatedAtAX5() {
        auditPopulated(size: Self.ax5, appearance: "light", audits: true)
    }

    func testGoalsAndActivityPopulatedInDark() {
        auditPopulated(size: nil, appearance: "dark", audits: false)
    }
}

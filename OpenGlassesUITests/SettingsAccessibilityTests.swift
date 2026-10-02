import XCTest

/// The settings hub, the accessibility category, and the model editor
/// (Plan DF P4) — ranks 4 and 5 on the plan's checklist, plus the one long-tail screen a user is
/// most likely to have to operate without sight: the editor for the model they talk to.
final class SettingsAccessibilityTests: AccessibilityAuditCase {

    // MARK: The hub

    /// The hub's one shape (Plan HA): every category as a row, in a fixed order, no Discover shelf.
    ///
    /// There is deliberately no settle wait before the audit here. This case failed on the
    /// nightly of 2026-09-22 (run 35739123389) with 14 Dynamic Type "partially unsupported"
    /// findings — one per title, subtitle and value of the category rows on screen, nothing
    /// else — and its screen recording shows the hub unchanged for the full five seconds between
    /// the tab appearing and the audit starting. The movement that produced the findings is the
    /// audit's own Dynamic Type sweep, which reflows the whole page a dozen times in a few
    /// seconds and occasionally reads a step before the reflow lands. `audit(_:screen:)` now
    /// measures such a result a second time before believing it — see
    /// `AuditConfirmationPolicy` for the evidence and the rule.
    func testSettingsHubPassesAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        XCTAssertFalse(app.staticTexts["Discover"].exists, "the Discover shelf is gone (Plan HA)")
        audit(app, screen: "Settings hub",
              deferring: [.secondaryCopyContrast, .contentUnderTheTabBar(of: app)])
    }

    /// Every category is a reachable row, whatever the phone has been used for.
    func testEveryCategoryIsARow() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        for title in ["AI & Personality", "Voice & Triggers", "Devices & Privacy", "Accessibility",
                      "Field Assist", "Look & Feel", "Tools & Actions", "Connections",
                      "Capture & Streaming", "Display & HUD", "Advanced", "Diagnostics & Support"] {
            XCTAssertTrue(scrollUntilFound(labelStartingWith: title, in: app).exists,
                          "\(title) is not a row on the settings hub")
        }
    }

    /// Pinned. The one category a user reaching for assistive features must be able to find.
    func testAccessibilityCategoryIsAlwaysAReachableRow() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Accessibility'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "The Accessibility category is not a row in the hub")
    }

    // MARK: The accessibility category

    func testAccessibilityCategoryPassesAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)

        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")
        audit(app, screen: "Settings — Accessibility category",
              deferring: [.secondaryCopyContrast, .systemFormChrome])
    }

    /// The master switch reveals three whole sections below it. Nothing about flipping a switch
    /// says "and now there is more page", so P2 made it announce — and the sections it reveals
    /// have to survive an audit of their own.
    func testAccessibilityCategoryRevealedSectionsPassAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        let master = app.switches["Enable Reading Accessibility"]
        XCTAssertTrue(master.waitForExistence(timeout: 60),
                      "The master switch is unnamed — a bare `Toggle(\"\")` reaches VoiceOver as "
                      + "an unnamed switch")
        // Drive it to a known state rather than assuming a tap flips it: the row is the target,
        // the switch is what carries the value, and a test that assumes the two agree fails for
        // a reason that has nothing to do with what it is measuring.
        if master.value as? String != "1" { master.switches.firstMatch.tap() }
        XCTAssertEqual(master.value as? String, "1",
                       "The master switch did not turn on when its row was tapped")

        // The revealed picker row, not the section header above it — a row is a control the user
        // can reach, and it is the thing whose arrival the announcement promises.
        let revealed = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Reading Level'")
        ).firstMatch
        XCTAssertTrue(revealed.waitForExistence(timeout: 20),
                      "Turning the master switch on revealed nothing")
        audit(app, screen: "Settings — Accessibility category, sections revealed",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])
    }

    /// Plan FF P1/PR3 — the launch switch, and the sentence that has to come with it.
    ///
    /// A switch that decides whether opening the app claims the microphone and opens the camera is
    /// the one control in this app whose *consequence* a blind wearer cannot check by looking. So
    /// two things are asserted: the switch is named (a bare `Toggle("")` reaches VoiceOver as an
    /// unnamed switch), and turning it on reveals a status sentence plus the route to the iOS
    /// permission page — the recovery that has no in-app equivalent.
    func testStartOnLaunchSwitchIsNamedAndExplainsWhatWillHappen() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        let toggle = app.switches["Start Blind Assistant When I Open the App"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 60),
                      "The launch switch is unnamed or missing")

        if toggle.value as? String != "1" { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, "1",
                       "The launch switch did not turn on when its row was tapped")

        let settingsRoute = app.buttons["Open iOS Settings for Avenkin"]
        XCTAssertTrue(settingsRoute.waitForExistence(timeout: 20),
                      "Turning the switch on revealed no route to the iOS permission page, which "
                      + "is the only place a refused microphone can be granted")

        audit(app, screen: "Settings — Accessibility category, start-on-launch on",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])

        // Leave the setting as it was found: it decides what the next launch does, and a UI test
        // must not hand the next case a session it did not ask for.
        toggle.switches.firstMatch.tap()
    }

    /// Plan FF P1/PR8 — the two new rows, and the processing summary screen itself.
    ///
    /// The readiness check is only asserted as a *reachable, named row*: tapping it would claim the
    /// glasses camera and speak a test line, and a UI test that starts hardware it cannot observe
    /// is a UI test that hangs. Its decisions are covered headlessly by
    /// `ReadinessWalkthroughTests`; what a UI test can prove is that a wearer can find it.
    func testTheReadinessAndProcessingRowsAreReachableAndTheSummaryPassesTheAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")
        tapRow(startingWith: "Accessibility", in: app)
        awaitScreen(app.navigationBars["Accessibility"], named: "The accessibility category")

        // The category is longer than a screen, and a `Form` only builds the rows it has reached,
        // so "does not exist yet" and "is not there" are the same query until it is scrolled.
        let readiness = scrollUntilFound(labelStartingWith: "Check the Assistant Is Ready", in: app)
        XCTAssertTrue(readiness.exists,
                      "The readiness check is not a reachable row in the accessibility category")

        let processing = scrollUntilFound(labelStartingWith: "How Your Requests Are Processed",
                                          in: app)
        XCTAssertTrue(processing.exists,
                      "The processing summary is not a reachable row in the accessibility category")
        processing.tap()

        awaitScreen(app.navigationBars["How Requests Are Processed"],
                    named: "The processing summary")
        // Every row is present, whatever this launch configuration routes them to.
        XCTAssertTrue(app.staticTexts["What you say"].waitForExistence(timeout: 20),
                      "The transcription row is missing from the processing summary")
        audit(app, screen: "Settings — How requests are processed",
              deferring: [.secondaryCopyContrast, .systemFormChrome])
    }

    /// Scroll a long settings category until a row exists, and return it. Returns the query either
    /// way, so the caller's assertion carries the failure message.
    private func scrollUntilFound(labelStartingWith prefix: String,
                                  in app: XCUIApplication,
                                  steps: Int = 10) -> XCUIElement {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        if element.waitForExistence(timeout: 5) { return element }
        for _ in 0..<steps {
            app.swipeUp()
            if element.exists { return element }
        }
        return element
    }

    // MARK: The model editor

    /// Reached through AI & Personality, the first row of the hub.
    func testModelEditorPassesAccessibilityAudit() {
        let app = launch([.configured])
        openTab("Settings", in: app)
        awaitScreen(app.navigationBars["Settings"], named: "The settings hub")

        tapRow(startingWith: "AI & Personality", in: app)
        awaitScreen(app.navigationBars["AI & Personality"], named: "The AI & Personality category")

        // A model row is one combined element: name, provider, whether it holds a key, whether it
        // takes images. Addressed by its leading name for that reason.
        tapRow(startingWith: "Apple Intelligence", in: app)

        awaitScreen(app.navigationBars["Edit Model"], named: "The model editor")
        audit(app, screen: "Settings — Model editor",
              deferring: [.secondaryCopyContrast, .systemFormChrome, .singleLineTextEntry])
    }
}

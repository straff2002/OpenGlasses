import XCTest

/// Plan MN P2 — the procedure step screen, photographed in both appearances and at the largest
/// accessibility text size, with no usable AI model on the phone (a keyless provider), so the run
/// is the no-model one. The open job runs the example bottling-line check, answered through its
/// first step: what is on screen is the CO2 step with its number pad, spec hint and trail.
///
/// Set `OG_SHOT_DIR` to write the PNGs somewhere as well as attaching them to the result bundle.
/// Every control is checked for a label here as well, since the system audit cannot run on every
/// host.
final class ProcedureStepScreenTests: AccessibilityAuditCase {

    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

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

    private func openTheStepScreen(dark: Bool = false, contentSize: String? = nil) -> XCUIApplication {
        var states: [LaunchState] = [.configured, .seedFieldJob, .seedProcedure]
        if dark { states.append(.darkAppearance) }
        let app = launch(states, contentSizeCategory: contentSize,
                         extraArguments: ["-OGUITestModelProvider", "anthropic"])
        var tab = app.tabBars.buttons["Jobs"]
        if !tab.waitForExistence(timeout: 90) {
            app.terminate()
            app.launch()
            tab = app.tabBars.buttons["Jobs"]
            XCTAssertTrue(tab.waitForExistence(timeout: 150), "the Job tab never appeared")
        }
        tab.tap()
        let jobRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Job 1005,")).firstMatch
        if jobRow.waitForExistence(timeout: 30) { jobRow.tap() }

        let open = app.buttons["procedure-open-step"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<25 where !(open.exists && open.isHittable) {
            (list.exists ? list : app).swipeUp(velocity: .slow)
        }
        awaitScreen(open, named: "The running procedure's row")
        open.tap()
        awaitScreen(app.staticTexts["procedure-position"], named: "The step screen")
        return app
    }

    /// Every button and field on the screen says what it is.
    private func assertEveryControlIsLabelled(_ app: XCUIApplication) {
        for element in app.buttons.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex
            + app.switches.allElementsBoundByIndex where element.exists {
            XCTAssertFalse(element.label.trimmingCharacters(in: .whitespaces).isEmpty,
                           "an unlabelled control: \(element.identifier) \(element.elementType.rawValue)")
        }
    }

    func testTheStepScreenWithNoModelLight() {
        let app = openTheStepScreen()
        XCTAssertTrue(app.staticTexts["Step 2"].exists)
        XCTAssertTrue(app.staticTexts["Running without the assistant: no AI model is set up on this phone."].exists)
        XCTAssertTrue(app.staticTexts["procedure-spec-hint"].exists)
        for key in ["1", "2", "0", "Delete", "Decimal point"] {
            XCTAssertTrue(app.buttons[key].exists, "the number pad's \(key) key")
        }
        assertEveryControlIsLabelled(app)
        save(app, named: "mn-p2-step-screen-light")

        // Type an in-spec reading: it is recorded, the rule says so, and Next goes on.
        app.buttons["2"].tap()
        app.buttons["Decimal point"].tap()
        app.buttons["6"].tap()
        app.buttons["procedure-record"].tap()
        let recorded = app.staticTexts["procedure-recorded"].firstMatch
        awaitScreen(recorded, named: "The recorded reading")
        XCTAssertTrue(recorded.label.contains("in spec"), recorded.label)
        save(app, named: "mn-p2-step-screen-recorded-light")
    }

    func testTheStepScreenWithNoModelDark() {
        let app = openTheStepScreen(dark: true)
        assertEveryControlIsLabelled(app)
        save(app, named: "mn-p2-step-screen-dark")
    }

    func testTheStepScreenAtTheLargestAccessibilitySize() {
        let app = openTheStepScreen(contentSize: Self.ax5)
        assertEveryControlIsLabelled(app)
        save(app, named: "mn-p2-step-screen-ax5")
        app.swipeUp(velocity: .slow)
        save(app, named: "mn-p2-step-screen-ax5-pad")
    }

    func testTheStepScreenAudit() {
        let app = openTheStepScreen()
        // The one finding on the first run was the sheet's system toolbar Close button (Dynamic
        // Type partially unsupported): system chrome, deferred as every Form screen defers it.
        audit(app, screen: "Procedure step screen — no model",
              deferring: [.secondaryCopyContrast, .systemFormChrome])
    }
}

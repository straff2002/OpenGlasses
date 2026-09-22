import XCTest

/// Plan FO P2c — photographs of the three sign-off screens, in both appearances.
///
/// Not an audit: these exist so a person can look at the step, the customer-facing sheet and the
/// acceptance block on a finished job and say whether they read. Everything is the shipping flow —
/// the close button, the step, the hand-over sheet — with only the job's state seeded.
///
/// Set `OG_SHOT_DIR` to write the PNGs somewhere as well as attaching them to the result bundle.
final class JobSignOffScreenshotTests: AccessibilityAuditCase {

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

    // MARK: - The close-flow step

    func testTheSignOffStepLight() {
        let app = launch([.configured, .seedFieldJob])
        openTheSignOffStep(app)
        save(app, named: "fo2c-step-light")
    }

    func testTheSignOffStepDark() {
        let app = launch([.configured, .seedFieldJob, .darkAppearance])
        openTheSignOffStep(app)
        save(app, named: "fo2c-step-dark")
    }

    // MARK: - The hand-over sheet

    func testTheHandOverSheetEmptyLight() {
        let app = launch([.configured, .seedFieldJob])
        openTheHandOverSheet(app)
        save(app, named: "fo2c-handover-empty-light")
    }

    func testTheHandOverSheetEmptyDark() {
        let app = launch([.configured, .seedFieldJob, .darkAppearance])
        openTheHandOverSheet(app)
        save(app, named: "fo2c-handover-empty-dark")
    }

    func testTheHandOverSheetSignedLight() {
        let app = launch([.configured, .seedFieldJob])
        openTheHandOverSheet(app)
        sign(app)
        save(app, named: "fo2c-handover-signed-light")
    }

    func testTheHandOverSheetSignedDark() {
        let app = launch([.configured, .seedFieldJob, .darkAppearance])
        openTheHandOverSheet(app)
        sign(app)
        save(app, named: "fo2c-handover-signed-dark")
    }

    /// The sheet is what a customer reads, and a customer with low vision reads it at AX5.
    func testTheHandOverSheetAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldJob], contentSizeCategory: Self.ax5)
        openTheHandOverSheet(app)
        save(app, named: "fo2c-handover-ax5")
    }

    // MARK: - The acceptance on a finished job

    func testTheAcceptanceBlockLight() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSignOff])
        openTheAcceptanceBlock(app)
        save(app, named: "fo2c-acceptance-light")
    }

    func testTheAcceptanceBlockDark() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSignOff, .darkAppearance])
        openTheAcceptanceBlock(app)
        save(app, named: "fo2c-acceptance-dark")
    }

    func testTheAcceptanceBlockAtTheLargestAccessibilitySize() {
        let app = launch([.configured, .seedFieldHistory, .seedFieldSignOff],
                         contentSizeCategory: Self.ax5)
        openTheAcceptanceBlock(app)
        save(app, named: "fo2c-acceptance-ax5")
    }

    // MARK: - Getting there

    static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    private func openJobTab(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Job"]
        if !tab.waitForExistence(timeout: 90) {
            app.terminate()
            app.launch()
            XCTAssertTrue(tab.waitForExistence(timeout: 120), "the Job tab never appeared")
        }
        tab.tap()
    }

    /// Close the seeded job, which puts the sign-off step in front of the technician. The seeded
    /// job carries no photographs, so the close confirmation comes first and the evidence review
    /// does not.
    private func openTheSignOffStep(_ app: XCUIApplication) {
        openJobTab(app)
        awaitScreen(app.staticTexts["Job 1005"], named: "The open job")
        let close = app.buttons["Close job"]
        scrollUntilVisible(close, in: app, named: "Close job")
        close.tap()
        confirmClose(app)
        awaitScreen(app.navigationBars["Customer sign-off"], named: "The sign-off step")
    }

    private func openTheHandOverSheet(_ app: XCUIApplication) {
        openTheSignOffStep(app)
        // At the largest text size the summary fills the step, so the button is below the fold —
        // and a `List` has not built a row it has not reached.
        let handOver = app.buttons["Hand to customer"]
        scrollUntilVisible(handOver, in: app, named: "Hand to customer")
        handOver.tap()
        awaitScreen(app.navigationBars["Please sign"], named: "The hand-over sheet")
    }

    /// A name and a signature, entered the way a customer would.
    ///
    /// The keyboard is dismissed before the pad is touched. It covers the bottom half of the
    /// sheet, and a drag that starts on it types rather than draws — which is what the first pass
    /// of this photographed.
    private func sign(_ app: XCUIApplication) {
        let name = app.textFields["Your name"]
        if name.waitForExistence(timeout: 20) {
            name.tap()
            name.typeText("Dana Okafor\n")
        }
        if app.keyboards.element.exists {
            app.staticTexts["Signature"].firstMatch.tap()
        }
        let pad = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Signature pad")).firstMatch
        scrollUntilVisible(pad, in: app, named: "Signature pad", swipes: 3)
        if pad.waitForExistence(timeout: 20) {
            let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7))
            let middle = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: middle)
            middle.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    private func openTheAcceptanceBlock(_ app: XCUIApplication) {
        openJobTab(app)
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Job 1004")).firstMatch
        // The past-jobs list is the whole screen, but at the largest text size the search field
        // above it can push the first row out of reach before the list has built it.
        scrollUntilVisible(row, in: app, named: "A past job row", swipes: 4)
        awaitScreen(row, named: "A past job row")
        row.tap()
        // At the largest text size the work record alone is several screens, and a `List` has not
        // built a section it has not reached — so the block is scrolled to rather than waited for.
        let block = app.staticTexts["Customer acceptance"]
        scrollUntilVisible(block, in: app, named: "The acceptance block", swipes: 20)
        awaitScreen(block, named: "The acceptance block")
        scrollUntilVisible(app.staticTexts["Signed on the technician's phone"], in: app,
                           named: "The acceptance line")
    }

    /// Confirm the "Close this job?" dialog. The destructive button carries the same words as the
    /// row that raised it, so it is reached through the presented dialog rather than by label
    /// alone — and a `confirmationDialog` surfaces as a sheet on the phone and as an alert in some
    /// presentations, so both are tried.
    private func confirmClose(_ app: XCUIApplication, file: StaticString = #filePath,
                              line: UInt = #line) {
        let inSheet = app.sheets.buttons["Close job"]
        if inSheet.waitForExistence(timeout: 10) {
            inSheet.tap()
            return
        }
        let inAlert = app.alerts.buttons["Close job"]
        if inAlert.waitForExistence(timeout: 10) {
            inAlert.tap()
            return
        }
        XCTFail("the close confirmation never appeared", file: file, line: line)
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication,
                                    named name: String, swipes: Int = 8,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        // Soft: the caller asserts on the screen it was looking for. A helper that failed here
        // would report a scrolling problem where the real one is further down.
        if !element.exists {
            XCTContext.runActivity(named: "\(name) did not come into reach after \(swipes) swipes") { _ in }
        }
    }
}
